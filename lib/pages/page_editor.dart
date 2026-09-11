import 'dart:async';
import 'dart:convert';
import 'package:tfc/widgets/panes/standard_dialog.dart';
import 'dart:io' show Platform;

import 'package:logger/logger.dart';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show kMiddleMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tfc_dart/core/fuzzy_match.dart';
import 'package:tfc/providers/page_manager.dart';
import '../page_creator/asset_update.dart';
import '../page_creator/assets/common.dart';
import '../page_creator/assets/editor_clipboard.dart';
import '../page_creator/assets/image.dart';
import '../page_creator/assets/image_store.dart';
import '../page_creator/assets/ethercat_link.dart';
import '../page_creator/assets/link_edit_overlay.dart';
import '../page_creator/assets/registry.dart';
import '../providers/page_images.dart';
import '../widgets/base_scaffold.dart';
import 'page_view.dart';
import '../widgets/zoomable_canvas.dart';
import '../widgets/panes/pane_chrome.dart' show PaneAction;
import '../widgets/leave_guard.dart';
import '../widgets/panes/side_pane.dart';
import '../widgets/bulk_property_editor.dart';
import '../page_creator/page.dart';
import '../core/startup_url.dart';
import '../providers/preferences.dart' show localPreferencesProvider;
import '../models/menu_item.dart';
import 'package:tfc_access/tfc_access.dart' show AccessGroup, AccessGroupInfo;
import '../route_registry.dart';
import '../routes.dart';
import '../providers/current_page_assets.dart';
import '../tech_docs/tech_doc_picker.dart';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import '../chat/ai_context_action.dart';
import '../chat/asset_context_menu.dart' show buildEditorAssetMenuItems;
import '../core/feature_flags.dart';
import '../chat/chat_overlay.dart' show ChatContext;
import '../chat/hamburger_context_menu.dart';
import '../chat/page_context_menu.dart';
import '../chat/palette_context_menu.dart';
import '../widgets/proposal_visual.dart';
import '../providers/proposal_state.dart';
import 'package:flutter/services.dart';

/// File-level logger. Diagnostics here must survive a windowed MSIX build
/// with no console, which is the one thing stderr cannot do.
final Logger _log = Logger();

/// Hit-tests whether a pointer position falls inside an asset's rotated
/// visual rect. The marquee gate uses this to decide between starting a
/// drag-selection rubber band (pointer down on empty canvas) and dragging
/// an asset (pointer down on an asset). An unrotated AABB test would fail
/// in both directions for any asset with a non-zero `angle`.
///
/// `pointer` is in the editor canvas's local coordinate system.
/// `cx`, `cy` are the asset centre in the same system.
/// `halfW`, `halfH` are the asset's unrotated half-extents.
/// `angleDegrees` is the asset's rotation in degrees (matches
/// `Coordinates.angle`).
@visibleForTesting
bool marqueeHitTestRotatedAsset({
  required Offset pointer,
  required double cx,
  required double cy,
  required double halfW,
  required double halfH,
  required double angleDegrees,
}) {
  final dx = pointer.dx - cx;
  final dy = pointer.dy - cy;
  final angleRad = angleDegrees * math.pi / 180;
  // Apply the inverse rotation (-angle) to project the pointer into the
  // asset's unrotated local frame, then test the half-extents.
  final cosA = math.cos(-angleRad);
  final sinA = math.sin(-angleRad);
  final localDx = dx * cosA - dy * sinA;
  final localDy = dx * sinA + dy * cosA;
  return localDx.abs() <= halfW && localDy.abs() <= halfH;
}

/// Whether [pointer] lands on [asset], as the editor decides it.
///
/// Two steps. The rotated rectangle first, which is the whole answer for
/// every asset drawn to fill its box. Then the asset's own shape, for the one
/// whose box is mostly empty: a cable's rectangle spans the two devices it
/// plugs into, so without the second step a run crossing the canvas would
/// claim every drag over that area and a marquee could not be started
/// anywhere near it.
///
/// The local conversion ignores rotation deliberately. Only a run refines its
/// hit shape, and a run is never rotated — its angle comes from where its
/// devices are, not from a field.
@visibleForTesting
bool editorHitTestAsset({
  required Offset pointer,
  required Asset asset,
  required List<Asset> assets,
  required Size canvas,
}) {
  final derived = asset.boxOn(assets, canvas);
  final cx = (derived?.center.dx ?? asset.coordinates.x) * canvas.width;
  final cy = (derived?.center.dy ?? asset.coordinates.y) * canvas.height;
  final w = (derived?.width ?? asset.size.width) * canvas.width;
  final h = (derived?.height ?? asset.size.height) * canvas.height;

  if (!marqueeHitTestRotatedAsset(
    pointer: pointer,
    cx: cx,
    cy: cy,
    halfW: w / 2,
    halfH: h / 2,
    angleDegrees: asset.coordinates.angle ?? 0.0,
  )) {
    return false;
  }
  return asset.hitTestBox(
    Offset(pointer.dx - (cx - w / 2), pointer.dy - (cy - h / 2)),
    Size(w, h),
    assets,
    canvas,
  );
}

/// Reorders [assets] so that [targets] sit beneath everything else.
///
/// Paint order is list order — `AssetStack` renders assets in sequence, so the
/// head of the list is the back of the stack. Members of [targets] keep their
/// own relative stacking; only their position relative to the rest changes.
///
/// Returns a new list; [assets] is not modified. Generic so the ordering can
/// be tested without building real assets.
@visibleForTesting
List<T> sendToBackOrder<T>(List<T> assets, Set<T> targets) {
  final moving = <T>[];
  final rest = <T>[];
  for (final asset in assets) {
    (targets.contains(asset) ? moving : rest).add(asset);
  }
  return [...moving, ...rest];
}

/// Reorders [assets] so that [targets] sit on top of everything else — the
/// mirror image of [sendToBackOrder]. Members of [targets] keep their own
/// relative stacking; only their position relative to the rest changes.
///
/// Returns a new list; [assets] is not modified.
@visibleForTesting
List<T> bringToFrontOrder<T>(List<T> assets, Set<T> targets) {
  final moving = <T>[];
  final rest = <T>[];
  for (final asset in assets) {
    (targets.contains(asset) ? moving : rest).add(asset);
  }
  return [...rest, ...moving];
}

/// Whether [targets] already occupy the back of the stack, i.e. the leading
/// run of [assets]. Empty or absent targets count as already-at-back, since
/// there is nothing to move.
@visibleForTesting
bool isAlreadyAtBack<T>(List<T> assets, Set<T> targets) {
  var seen = 0;
  for (var i = 0; i < assets.length; i++) {
    if (targets.contains(assets[i])) {
      // Out of the leading run: something else is already below it.
      if (i != seen) return false;
      seen++;
    }
  }
  return true;
}

/// Whether [targets] already occupy the front of the stack, i.e. the trailing
/// run of [assets]. Empty or absent targets count as already-at-front, since
/// there is nothing to move. Mirrors [isAlreadyAtBack].
@visibleForTesting
bool isAlreadyAtFront<T>(List<T> assets, Set<T> targets) {
  var seen = 0;
  for (var i = assets.length - 1; i >= 0; i--) {
    if (targets.contains(assets[i])) {
      // Out of the trailing run: something else is already above it.
      if (i != assets.length - 1 - seen) return false;
      seen++;
    }
  }
  return true;
}

/// One asset's placement on the canvas, in the normalized 0..1 units the
/// editor stores. Exists so [rotateGroup] can be exercised — and reasoned
/// about — without building real assets.
@visibleForTesting
@immutable
class AssetPlacement {
  const AssetPlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.angle,
  });

  /// Centre point, as a fraction of the canvas (matches `Coordinates`).
  final double x;
  final double y;

  /// Extents, as a fraction of the canvas (matches `RelativeSize`).
  final double width;
  final double height;

  /// Rotation in degrees, clockwise on screen. Null means "never rotated";
  /// [rotateGroup] preserves that distinction because `AssetStack` only
  /// applies the page's mirror transform to assets with a non-null angle.
  final double? angle;

  @override
  String toString() =>
      'AssetPlacement(x: $x, y: $y, width: $width, height: $height, '
      'angle: $angle)';
}

/// Normalizes an angle in degrees to [0, 360).
double _normalizeAngle(double degrees) {
  final wrapped = degrees % 360;
  return wrapped < 0 ? wrapped + 360 : wrapped;
}

/// cos/sin packed as (dx, dy), exact for quarter turns.
///
/// `math.cos(pi / 2)` is 6.1e-17, not 0, so a nominally rigid 90° turn would
/// leak a little of each axis into the other — a systematic error that repeats
/// in the same direction every rotation. The quarter turns are the only
/// rotations the editor's menu offers, so they are table lookups rather than
/// trig. Rounding in the surrounding arithmetic still costs an ulp or so per
/// turn; this only removes the part that would accumulate.
Offset _rotationFactors(double degrees) {
  final normalized = _normalizeAngle(degrees);
  if (normalized == 0) return const Offset(1, 0);
  if (normalized == 90) return const Offset(0, 1);
  if (normalized == 180) return const Offset(-1, 0);
  if (normalized == 270) return const Offset(0, -1);
  final radians = normalized * math.pi / 180;
  return Offset(math.cos(radians), math.sin(radians));
}

/// Rotates [placements] as one rigid group about the centre of their combined
/// bounding box: every asset both spins on its own centre and orbits the
/// group's, the way a selection rotates in a drawing tool.
///
/// [degrees] is clockwise on screen, matching `Coordinates.angle` and
/// `Transform.rotate`.
///
/// [aspectRatio] is the canvas's width / height. It is required because x and
/// y are normalized independently against a canvas that is not square — a
/// rotation applied directly to normalized coordinates would shear the group.
/// The maths therefore runs in units of canvas height (x scaled by
/// [aspectRatio]) and converts back at the end.
///
/// The bounding box is built from each asset's *rotated* extents, so a quarter
/// turn maps the box onto itself and the group's centre stays put. Combined
/// with the exact quarter-turn factors above, that makes CW-then-CCW a round
/// trip to within a rounding ulp, with no direction the error can accumulate
/// in.
///
/// A group that would leave the canvas is translated back in as a unit rather
/// than clamped per asset, which would collapse the layout. A group too large
/// to fit is aligned to the top/left edge and may overhang; as a last resort
/// centres are clamped into 0..1 so no asset ends up unreachable off-canvas.
///
/// Half-extents of an asset's axis-aligned bounding box once its own rotation
/// is applied — the same formula `AssetStack` uses to size the Positioned that
/// holds a rotated visual. In units of canvas height, so [aspect] scales the
/// width in and the caller divides x back out.
///
/// Uses the exact quarter-turn factors rather than raw trig for the same
/// reason the orbit in [rotateGroup] does: the box decides where the group
/// centre sits, so noise here would drift the whole selection.
Offset _halfExtents(double width, double height, double? angle, double aspect) {
  final factors = _rotationFactors(angle ?? 0.0);
  final cosA = factors.dx.abs();
  final sinA = factors.dy.abs();
  final halfW = width * aspect / 2;
  final halfH = height / 2;
  return Offset(halfW * cosA + halfH * sinA, halfW * sinA + halfH * cosA);
}

/// Returns a new list positionally matching [placements]; nothing is mutated.
@visibleForTesting
List<AssetPlacement> rotateGroup({
  required List<AssetPlacement> placements,
  required double degrees,
  required double aspectRatio,
}) {
  if (placements.isEmpty) return const [];
  // A degenerate canvas has no meaningful aspect; fall back to square rather
  // than producing NaN coordinates.
  final aspect = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0;

  Offset halfExtents(double width, double height, double? angle) =>
      _halfExtents(width, height, angle, aspect);

  // 1) Bounding box of the selection, in canvas-height units.
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final p in placements) {
    final half = halfExtents(p.width, p.height, p.angle);
    minX = math.min(minX, p.x * aspect - half.dx);
    maxX = math.max(maxX, p.x * aspect + half.dx);
    minY = math.min(minY, p.y - half.dy);
    maxY = math.max(maxY, p.y + half.dy);
  }
  final centreX = (minX + maxX) / 2;
  final centreY = (minY + maxY) / 2;

  // 2) Orbit each centre about the group centre and spin the asset itself.
  final factors = _rotationFactors(degrees);
  final rotated = <AssetPlacement>[];
  for (final p in placements) {
    final dx = p.x * aspect - centreX;
    final dy = p.y - centreY;
    final newAngle = _normalizeAngle((p.angle ?? 0.0) + degrees);
    rotated.add(AssetPlacement(
      x: (centreX + dx * factors.dx - dy * factors.dy) / aspect,
      y: centreY + dx * factors.dy + dy * factors.dx,
      width: p.width,
      height: p.height,
      // Back at zero means back to null. AssetStack skips the page's mirror
      // transform for a null angle, so rotating a selection and rotating it
      // back has to restore the null or the visual would start flipping on
      // mirrored pages — a no-op round trip must really be a no-op. The cost
      // is that an angle stored explicitly as 0 collapses to null.
      angle: newAngle == 0 ? null : newAngle,
    ));
  }

  // 3) Translate the group back onto the canvas if the rotation pushed it off.
  var shiftX = 0.0;
  var shiftY = 0.0;
  var rMinX = double.infinity;
  var rMinY = double.infinity;
  var rMaxX = double.negativeInfinity;
  var rMaxY = double.negativeInfinity;
  for (final p in rotated) {
    final half = halfExtents(p.width, p.height, p.angle);
    rMinX = math.min(rMinX, p.x * aspect - half.dx);
    rMaxX = math.max(rMaxX, p.x * aspect + half.dx);
    rMinY = math.min(rMinY, p.y - half.dy);
    rMaxY = math.max(rMaxY, p.y + half.dy);
  }
  // Pull the leading edge in first, so an oversized group overhangs the
  // bottom/right rather than the top/left where it is harder to grab.
  if (rMaxX > aspect) shiftX = aspect - rMaxX;
  if (rMinX + shiftX < 0) shiftX = -rMinX;
  if (rMaxY > 1) shiftY = 1 - rMaxY;
  if (rMinY + shiftY < 0) shiftY = -rMinY;

  if (shiftX == 0 && shiftY == 0) return rotated;
  return [
    for (final p in rotated)
      AssetPlacement(
        x: (p.x + shiftX / aspect).clamp(0.0, 1.0),
        y: (p.y + shiftY).clamp(0.0, 1.0),
        width: p.width,
        height: p.height,
        angle: p.angle,
      ),
  ];
}

/// Translates [placements] as a rigid group so the centre of their combined
/// bounding box lands on ([targetX], [targetY]), both in 0..1 canvas
/// fractions. Backs the context menu's "Paste here".
///
/// Same conventions as [rotateGroup]: extents are measured with each asset's
/// own rotation applied, the maths runs in canvas-height units so a wide
/// canvas does not skew the drop, and a group that would overhang the canvas
/// is pulled back on as a unit — leading edge first, so one too large to fit
/// overhangs the bottom/right — with a final per-centre clamp so no asset
/// ends up unreachable off-canvas.
@visibleForTesting
List<AssetPlacement> placeGroupAt({
  required List<AssetPlacement> placements,
  required double targetX,
  required double targetY,
  required double aspectRatio,
}) {
  if (placements.isEmpty) return const [];
  // A degenerate canvas has no meaningful aspect; fall back to square rather
  // than producing NaN coordinates.
  final aspect = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0;

  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final p in placements) {
    final half = _halfExtents(p.width, p.height, p.angle, aspect);
    minX = math.min(minX, p.x * aspect - half.dx);
    maxX = math.max(maxX, p.x * aspect + half.dx);
    minY = math.min(minY, p.y - half.dy);
    maxY = math.max(maxY, p.y + half.dy);
  }

  var shiftX = targetX.clamp(0.0, 1.0) * aspect - (minX + maxX) / 2;
  var shiftY = targetY.clamp(0.0, 1.0) - (minY + maxY) / 2;

  if (maxX + shiftX > aspect) shiftX = aspect - maxX;
  if (minX + shiftX < 0) shiftX = -minX;
  if (maxY + shiftY > 1) shiftY = 1 - maxY;
  if (minY + shiftY < 0) shiftY = -minY;

  return [
    for (final p in placements)
      AssetPlacement(
        x: (p.x + shiftX / aspect).clamp(0.0, 1.0),
        y: (p.y + shiftY).clamp(0.0, 1.0),
        width: p.width,
        height: p.height,
        angle: p.angle,
      ),
  ];
}

/// Which way a selection is flipped.
enum MirrorAxis {
  /// Left becomes right: assets swap sides across a vertical line through the
  /// selection's centre.
  horizontal,

  /// Top becomes bottom: assets swap across a horizontal line through it.
  vertical,
}

/// Reflects [placements] about the centre of their combined bounding box.
///
/// Both the layout and each asset's own orientation are reflected, the way a
/// selection flips in a drawing tool: a line of assets comes back in the
/// opposite order, and one that was leaning right leans left.
///
/// The angle is reflected rather than the artwork, because an asset has no
/// per-asset mirror flag to set — only the page-wide one in `AssetStackConfig`.
/// For the equipment these pages are made of, whose glyphs are symmetric about
/// their own long axis, reflecting the angle is the same picture. It is not
/// for a chiral glyph, which comes back rotated rather than mirrored.
///
/// One consequence worth knowing before reaching for this: a horizontal flip
/// maps angle 0 to 180, so assets that were never rotated come back explicitly
/// upside down. A vertical flip maps 0 to 0 and leaves them alone.
///
/// [aspectRatio] is the canvas's width / height, needed for the same reason
/// [rotateGroup] needs it — x and y are normalized against a canvas that is
/// not square, so a rotated asset's bounding box cannot be measured without
/// it. The reflection itself acts on one axis at a time and so cannot shear.
///
/// Nothing can leave the canvas: reflecting an angle leaves |cos| and |sin|
/// unchanged, so every asset's bounding box keeps its size and the group's box
/// maps exactly onto itself.
///
/// Returns a new list positionally matching [placements]; nothing is mutated.
@visibleForTesting
List<AssetPlacement> mirrorGroup({
  required List<AssetPlacement> placements,
  required MirrorAxis axis,
  required double aspectRatio,
}) {
  if (placements.isEmpty) return const [];
  final aspect = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.0;

  // Bounding box of the selection, in canvas-height units — the same box
  // rotateGroup turns about.
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = double.negativeInfinity;
  var maxY = double.negativeInfinity;
  for (final p in placements) {
    final half = _halfExtents(p.width, p.height, p.angle, aspect);
    minX = math.min(minX, p.x * aspect - half.dx);
    maxX = math.max(maxX, p.x * aspect + half.dx);
    minY = math.min(minY, p.y - half.dy);
    maxY = math.max(maxY, p.y + half.dy);
  }
  final centreX = (minX + maxX) / 2;
  final centreY = (minY + maxY) / 2;

  return [
    for (final p in placements)
      () {
        final angle = p.angle ?? 0.0;
        // Screen axes: x right, y down, angle clockwise, so an asset points
        // along (cos a, sin a). Reflecting x gives (-cos a, sin a), which is
        // the direction at 180 - a; reflecting y gives (cos a, -sin a), which
        // is -a.
        final newAngle = _normalizeAngle(
          axis == MirrorAxis.horizontal ? 180 - angle : -angle,
        );
        return AssetPlacement(
          x: axis == MirrorAxis.horizontal
              ? ((2 * centreX - p.x * aspect) / aspect).clamp(0.0, 1.0)
              : p.x,
          y: axis == MirrorAxis.vertical
              ? (2 * centreY - p.y).clamp(0.0, 1.0)
              : p.y,
          width: p.width,
          height: p.height,
          // Back at zero means back to null, for the reason spelled out in
          // rotateGroup: AssetStack skips the page's mirror transform for a
          // null angle, so a round trip has to restore it.
          angle: newAngle == 0 ? null : newAngle,
        );
      }(),
  ];
}

/// The axis a selection is lined up along.
enum AlignAxis {
  /// Assets end up in a horizontal row: one shared y, x untouched.
  horizontal,

  /// Assets end up in a vertical column: one shared x, y untouched.
  vertical,
}

/// The coordinate [axis] alignment moves, for each of [placements].
Iterable<double> _alignedCoordinates(
        List<AssetPlacement> placements, AlignAxis axis) =>
    placements.map((p) => axis == AlignAxis.horizontal ? p.y : p.x);

/// Lines [placements] up on [axis], moving every asset's centre onto the
/// midpoint between the two outermost centres.
///
/// Centres, not edges: assets of different sizes end up with their middles on
/// one line and their edges ragged. That is what makes this the one selection
/// action that needs no canvas aspect ratio — it writes a constant into a
/// single normalized axis and leaves the other alone, so there is no
/// cross-axis maths to get wrong.
///
/// The line is the midpoint of the extremes rather than the mean, matching
/// what a drawing tool does: the two outermost assets move symmetrically
/// toward each other instead of the line being dragged around by whichever
/// side happens to be crowded.
///
/// Returns a new list positionally matching [placements]; nothing is mutated.
@visibleForTesting
List<AssetPlacement> alignGroup({
  required List<AssetPlacement> placements,
  required AlignAxis axis,
}) {
  if (placements.isEmpty) return const [];

  final coordinates = _alignedCoordinates(placements, axis);
  final line =
      (coordinates.reduce(math.min) + coordinates.reduce(math.max)) / 2;

  return [
    for (final p in placements)
      AssetPlacement(
        x: axis == AlignAxis.vertical ? line : p.x,
        y: axis == AlignAxis.horizontal ? line : p.y,
        width: p.width,
        height: p.height,
        angle: p.angle,
      ),
  ];
}

/// Whether [placements] already sit on one line along [axis], so the menu
/// entry can be disabled rather than pushing a no-op onto the undo history.
///
/// Exact equality is the right test, not a tolerance: [alignGroup] writes the
/// identical value into every asset, so a selection it has just aligned reads
/// back as aligned. Fewer than two assets have nothing to line up.
@visibleForTesting
bool isAlreadyAligned(List<AssetPlacement> placements, AlignAxis axis) {
  if (placements.length < 2) return true;
  final coordinates = _alignedCoordinates(placements, axis);
  return coordinates.every((c) => c == coordinates.first);
}

/// Projects a drag delta from the rotated GestureDetector's local frame
/// back into the canvas (parent) frame. The editor's per-asset
/// GestureDetector lives inside `Transform.rotate(angleRadians)` (so the
/// hit area follows the rotated visual), which means `DragUpdateDetails.delta`
/// is also expressed in that rotated frame — a screen-right drag at angle
/// 90° arrives as local-down. This helper rotates the delta back so the
/// editor can apply it to the asset's canvas-space coordinates directly.
///
/// For `angleDegrees == 0` the rotation is identity and the returned offset
/// equals the input.
@visibleForTesting
Offset projectDragDeltaToCanvas({
  required Offset delta,
  required double angleDegrees,
}) {
  final angleRad = angleDegrees * math.pi / 180;
  final cosA = math.cos(angleRad);
  final sinA = math.sin(angleRad);
  return Offset(
    delta.dx * cosA - delta.dy * sinA,
    delta.dx * sinA + delta.dy * cosA,
  );
}

/// Pairs the assets now on the canvas with the same assets in a restored undo
/// snapshot: for each entry of [live], the index of its counterpart in
/// [restored], or null where it has none (the undo removes it).
///
/// Undo re-parses the page, so every asset comes back as a fresh instance and
/// anything the editor was holding — the selection, the open config pane —
/// points at objects that are no longer on the canvas. Assets carry no id to
/// re-find them by, so the pairing is made from what is at hand:
///
///  * assets that serialize identically pair up in list order. That covers
///    everything the undone edit left alone, and — when the edit was a
///    restack — everything it touched as well, which is why this pass runs
///    before the positional one rather than instead of it.
///  * whatever is left over on each side is what the edit changed, and pairs
///    positionally: the operations that change an asset's contents never also
///    move it in the list, so the leftovers still line up. Unequal leftover
///    counts or a type mismatch means the undo added or removed assets rather
///    than editing one, and those go unpaired.
@visibleForTesting
List<int?> matchAssetsAcrossUndo(
  List<Map<String, dynamic>> live,
  List<Map<String, dynamic>> restored,
) {
  final paired = List<int?>.filled(live.length, null);
  final claimed = List<bool>.filled(restored.length, false);

  final byEncoding = <String, List<int>>{};
  for (var i = 0; i < restored.length; i++) {
    (byEncoding[jsonEncode(restored[i])] ??= <int>[]).add(i);
  }
  final consumed = <String, int>{};
  for (var i = 0; i < live.length; i++) {
    final encoding = jsonEncode(live[i]);
    final candidates = byEncoding[encoding];
    if (candidates == null) continue;
    final next = consumed[encoding] ?? 0;
    if (next >= candidates.length) continue;
    consumed[encoding] = next + 1;
    paired[i] = candidates[next];
    claimed[candidates[next]] = true;
  }

  final liveLeft = [
    for (var i = 0; i < live.length; i++)
      if (paired[i] == null) i
  ];
  final restoredLeft = [
    for (var i = 0; i < restored.length; i++)
      if (!claimed[i]) i
  ];
  if (liveLeft.length != restoredLeft.length) return paired;
  for (var i = 0; i < liveLeft.length; i++) {
    if (live[liveLeft[i]][constAssetName] !=
        restored[restoredLeft[i]][constAssetName]) {
      return paired;
    }
  }
  for (var i = 0; i < liveLeft.length; i++) {
    paired[liveLeft[i]] = restoredLeft[i];
  }
  return paired;
}

/// The names of the top-level properties whose values differ between two
/// encodings of one asset, or null when either is not a JSON object and the
/// question cannot be answered.
///
/// The config pane mutates its asset in place, so comparing its serialization
/// is the only signal the editor gets that something changed (see
/// [_PageEditorState._syncConfigEdits]); this says *what* changed, which is
/// what lets a run of edits to the same property fold into one undo entry.
@visibleForTesting
Set<String>? changedTopLevelKeys(String before, String after) {
  Map<String, dynamic>? asObject(String encoded) {
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  final a = asObject(before);
  final b = asObject(after);
  if (a == null || b == null) return null;
  final changed = <String>{};
  for (final key in {...a.keys, ...b.keys}) {
    if (jsonEncode(a[key]) != jsonEncode(b[key])) changed.add(key);
  }
  return changed;
}

/// One entry of the editor's undo history.
///
/// The pages travel as their encoded JSON rather than as a live copy — see
/// [_PageEditorState._undoHistory] for why — but a page map on its own does
/// not describe the editor. Which page is open and how the top level is
/// ordered are edited here too, and the top-level order includes
/// app-registered destinations that appear in no page's JSON at all, so both
/// ride along: an undo that left them behind could strand the operator on a
/// page the restored map no longer has.
@immutable
class _EditorSnapshot {
  const _EditorSnapshot({
    required this.pagesJson,
    required this.currentPage,
    required this.topLevelOrder,
    required this.navOrderDirty,
  });

  final String pagesJson;
  final String? currentPage;
  final List<String> topLevelOrder;
  final bool navOrderDirty;
}

class PageEditor extends ConsumerStatefulWidget {
  /// Optional proposal JSON passed via Beamer route data.
  /// When non-null, the editor pre-populates from the proposal instead of
  /// loading only from [pageManagerProvider].
  final String? proposalData;

  const PageEditor({super.key, this.proposalData});

  /// How many times the editor has re-encoded the whole page map. Encoding is
  /// O(everything on every page), so tests pin that continuous gestures do
  /// not do it per tick — see [_PageEditorState._currentJsonStale].
  @visibleForTesting
  static int debugJsonEncodes = 0;

  @override
  ConsumerState<PageEditor> createState() => _PageEditorState();
}

class _PageEditorState extends ConsumerState<PageEditor> {
  /// Undo snapshots as encoded page maps, not live copies. A live deep copy
  /// (encode + decode + re-parse of every asset on every page) on each
  /// key-down made a single arrow nudge lag behind the finger on big
  /// projects; the encoded string is already at hand in [_currentJson], so
  /// taking a snapshot is free and the decode is deferred to the rare undo.
  final List<_EditorSnapshot> _undoHistory = [];
  bool _showPalette = false;

  /// True while the pan key is held. The editor has one mode: a drag on empty
  /// canvas rubber-bands a selection, and this is what temporarily turns that
  /// drag back into a canvas pan.
  ///
  /// There is nothing to pan at 1:1 — `ZoomableCanvas` has `minScale: 1.0` and
  /// no boundary margin, so the child exactly fills the viewport — which is
  /// why panning can afford to be the held-key gesture and marquee the plain
  /// one, rather than the other way round.
  bool _isPanKeyHeld = false;

  Offset? _selectionStart;
  Offset? _selectionCurrent;
  Set<Asset> _selectedAssets = {};

  /// The selection as it stood when the marquee started. Every move recomputes
  /// the selection as this snapshot XOR the boxed assets, so a Ctrl/Cmd-held
  /// marquee toggles against what was already selected — the drag-shaped twin
  /// of the modifier-click in [_handleAssetSelection] — instead of replacing
  /// it. Snapshotting at pointer down (rather than reading the live selection)
  /// keeps assets from flickering in and out as the box grows and shrinks over
  /// them. Without a modifier the snapshot is empty and XOR degenerates to
  /// "exactly what the box covers".
  Set<Asset> _marqueeBaseSelection = {};

  /// True between an asset's pan start and the following pointer up, so a drag
  /// that began on an asset cannot also grow a marquee behind it.
  bool _isDraggingAsset = false;

  /// The canvas's last laid-out constraints. The keyboard handler sits above
  /// the `LayoutBuilder`, and [_rotateAssets] needs the aspect ratio, so the
  /// builder leaves it here on the way past.
  BoxConstraints? _canvasConstraints;

  /// The canvas `LayoutBuilder`'s context, stashed the same way as
  /// [_canvasConstraints]: [_assetScreenRect] walks it to find a tapped
  /// asset's rendered element, and [_openConfigPane] has no path to that
  /// context of its own.
  BuildContext? _canvasContext;

  /// The keys themselves are handled globally (see [_onShortcutKey]), so this
  /// node no longer routes them; it exists to *take focus away*. The config
  /// pane docks in the root overlay, and a text field there keeps keyboard
  /// focus — muting every shortcut via the text-field guard — until something
  /// pulls it back. Clicking the canvas does (see the Listener around
  /// [ZoomableCanvas]), as does the pane closing.
  final FocusNode _shortcutFocus =
      FocusNode(debugLabel: 'PageEditor shortcuts');
  String? _copiedAssets;
  Map<String, AssetPage> _temporaryPages = {};
  String? _currentPage;

  /// Working copy of [PageManager.topLevelOrder]: the full top level — pages
  /// and app-registered destinations alike — as arranged in the Pages dialog.
  List<String> _topLevelOrder = [];

  /// True when [_topLevelOrder] differs from what was loaded. Tracked apart
  /// from [_hasUnsavedChanges]'s JSON compare because app-registered items are
  /// not part of the pages JSON at all.
  bool _navOrderDirty = false;

  /// The URL this station opens on at startup, as shown in the Pages dialog.
  /// Device-local (see [localPreferencesProvider]) and written the moment it
  /// is toggled — it is not part of the shared pages JSON, so the editor's
  /// save/undo machinery has no say over it.
  String _startupUrl = startupUrlDefault;

  /// Backs the palette's search box. A controller rather than a bare string:
  /// the palette is torn down whenever it is closed, and a controller-less
  /// TextField would come back empty while the remembered query kept
  /// filtering the grid.
  final TextEditingController _paletteSearchController =
      TextEditingController();
  String _savedJson = '';
  String _currentJson = '';

  /// True while [_currentJson] lags the pages. Continuous gestures — a drag,
  /// a held arrow key — change coordinates on every pointer event or key
  /// repeat, and re-encoding every page each tick is what made moving assets
  /// lag on big projects. Those paths set this flag instead and the encode
  /// runs once when the gesture settles (pointer up / key up). While the flag
  /// is up, [_hasUnsavedChanges] simply reports dirty: mid-gesture that is
  /// always the right answer, and the settle recompute restores the exact
  /// compare for the one case it is not (moved back onto the saved spot).
  bool _currentJsonStale = false;

  /// Path of the tree row currently being dragged in the Pages dialog, so the
  /// drop zones can show whether they would take it.
  String? _dragPagePath;

  /// The Pages dialog's scrolling tree, driven directly while a row is dragged
  /// near an edge — Draggable does not scroll its parent list on its own, so
  /// without this a destination off screen could not be reached.
  final ScrollController _treeScrollController = ScrollController();
  final GlobalKey _treeViewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  double _autoScrollStep = 0;

  /// True when the editor was opened with AI proposal data that has not yet
  /// been saved by the operator.
  bool _isProposal = false;
  String? _proposalTitle;

  /// Every proposal folded into the pending edit.
  ///
  /// `asset_update` proposals are independent patches to different assets, so
  /// a queue of them can be applied in one pass and accepted with one save --
  /// otherwise binding N children means N accept-and-save round trips.
  /// `page` and `asset` proposals replace or append wholesale, so those are
  /// still applied one at a time.
  final List<int> _proposalIds = [];

  /// Ids already accepted or rejected. acceptProposal/rejectProposal each
  /// await a database write before dropping the proposal from state, so their
  /// removals land *after* the batch has been cleared -- and every removal
  /// fires the state listener. Without this the listener treats whatever has
  /// not been removed yet as a brand new batch and re-applies it, which is why
  /// a reject could leave the change on the page.
  /// The banner's callback slots, captured when publishing.
  ///
  /// Riverpod forbids `ref` inside dispose() -- "Cannot use ref after the
  /// widget was disposed" -- and these are plain (non-autoDispose)
  /// StateProviders, so their controllers outlive this State and can be held.
  StateController<Future<void> Function()?>? _commitSlot;
  StateController<Future<void> Function()?>? _discardSlot;

  /// The slot advertising this editor to the banner's View / "Review all",
  /// held for the same reason as the two above.
  StateController<ProposalReviewEntry?>? _reviewSlot;

  /// The proposal this editor was last asked to review, when it was handed one
  /// while already on screen.
  ///
  /// Stands in for [widget]`.proposalData`, which only ever carries the
  /// proposal the editor was *built* with: re-entering an open editor cannot
  /// change it (see [ProposalReviewEntry]).
  String? _reviewData;

  /// The provider container the banner's accept and reject work through,
  /// captured while this editor is still alive.
  ///
  /// Same reason the slots above are held: the banner outlives this editor.
  /// It is published once and stays up while the operator navigates, and
  /// accepting a batch can navigate out from under this State, so by the time
  /// the work runs `ref` throws and `mounted` is false. That is how a batch
  /// of asset updates got its pages written and not one of its proposals
  /// marked accepted, and came back on the next load. A ProviderContainer
  /// belongs to the ProviderScope at the app root, so it outlives this widget
  /// and can be held safely.
  ProviderContainer? _container;

  final Set<int> _consumedProposalIds = {};

  /// Assets that were added by the AI proposal (for visual indicators).
  Set<Asset> _proposedAssets = {};

  /// Snapshot of pages before proposal was applied (for reject/revert).
  Map<String, AssetPage>? _preProposalPages;

  /// Watches operator decisions made on surfaces that never ask this editor.
  ///
  /// The banner's per-row reject and the chat batch card's reject-all only
  /// drop the proposal from [proposalStateProvider]; they know nothing about
  /// the copy this editor staged into [_temporaryPages]. See
  /// [_onProposalFeedback] for what happens on such a decision.
  StreamSubscription<ProposalFeedback>? _feedbackSub;

  /// The asset whose configuration pane is docked open, if any. The pane is
  /// non-modal, so the canvas keeps taking taps and drags while it is up and
  /// tapping another asset just re-points the pane at it.
  Asset? _configAsset;

  /// Drives [_syncConfigEdits]. Config editors mutate their asset in place and
  /// rebuild only themselves, so this is the editor's only general signal that
  /// something in the pane changed — see [_assetSnapshot].
  Timer? _configWatch;
  String? _configSnapshot;

  /// The asset properties the open pane's current undo entry already covers,
  /// or null when it has none open. Edits arrive one serialization diff at a
  /// time — a keystroke, a slider tick — and an entry per diff would flush the
  /// 50-deep history with one typed label, so a run of changes to the same
  /// properties folds into the entry the first of them pushed. Reaching for a
  /// different property, or doing anything else at all (see [_saveToHistory]),
  /// ends the run.
  Set<String>? _configEditKeys;

  /// How often the open pane is compared against the canvas. Short enough that
  /// typing reads as live; pointer events sync straight away regardless.
  static const Duration _configWatchInterval = Duration(milliseconds: 100);

  /// Wider than an equipment pane: asset config editors are dense forms, and
  /// several were written against a full-screen dialog. The pane carries a
  /// resize handle, and this follows it — a composite device (a Beckhoff bus
  /// coupler, an Advantys head) wants a lot more room than an LED, and the
  /// width you drag it to is the one the next asset opens at.
  double _configPaneWidth = 520;

  /// The selection the properties pane is showing, or null when it is closed.
  ///
  /// Held apart from [_selectedAssets] so that a change to the selection can
  /// be spotted (see [_refreshBulkPane]) — the pane is built once into an
  /// overlay entry and does not rebuild just because this editor did.
  List<Asset>? _bulkPaneSelection;

  /// Ticks whenever the open properties pane's view of the world goes stale:
  /// the selection changed, or the assets moved under it. The pane listens
  /// and re-reads its rows; nothing else does, so the notifier is only
  /// touched while it is open.
  final ValueNotifier<int> _bulkRevision = ValueNotifier<int>(0);

  /// Narrower than [_configPaneWidth]: a properties grid is a column of short
  /// fields, not the dense forms the per-asset editors grew into.
  double _bulkPaneWidth = 360;

  List<Asset> get assets {
    if (_currentPage == null) {
      return [];
    }
    if (_temporaryPages[_currentPage] == null) {
      return [];
    }
    return _temporaryPages[_currentPage]!.assets;
  }

  @override
  void initState() {
    super.initState();
    // Global, like the side pane's Escape: the shortcuts must fire wherever
    // keyboard focus happens to sit. A focus-scoped handler goes deaf the
    // moment focus parks outside this page's subtree — the root-overlay
    // config pane, a just-dismissed dialog — and an operator whose Ctrl+Z
    // does nothing has no way to see why. [_onShortcutKey] stands down for
    // text fields, stacked routes and floating dialogs instead.
    HardwareKeyboard.instance.addHandler(_onShortcutKey);
    // Leaving with unsaved edits used to drop them without a word; the only
    // hint was the Save button having turned orange. The navigation chrome
    // asks this guard before it beams away.
    LeaveGuard.set(_confirmLeave);
    // A decision can land on a surface that never asks this editor: the
    // banner's per-row reject and the chat batch card's reject-all only drop
    // the proposal from state. The staged assets stayed on the canvas, and
    // the operator's next save wrote them as if they had been accepted
    // (2026-09-02: a rejected 35-asset "ST101 cabinet layout" proposal
    // persisted to /+ST101). Every decision surface reports to the feedback
    // stream, so it is what un-stages here -- see [_onProposalFeedback].
    try {
      _feedbackSub = ref
          .read(proposalFeedbackProvider)
          .stream
          .listen(_onProposalFeedback);
    } catch (_) {
      // Provider unavailable in tests -- outside decisions cannot reach a
      // staged batch there.
    }
    ref.read(pageManagerProvider.future).then((pageManager) {
      setState(() {
        _temporaryPages = pageManager.copyWith().pages;
        _topLevelOrder = List.of(pageManager.topLevelOrder);
        _currentPage = pageManager.pages.keys.firstOrNull;

        // Apply proposal data if present.
        //
        // Arriving from the banner's "Review all" hands us a single
        // proposalJson, but the queue behind it is what the operator asked to
        // review. Batch every pending asset proposal instead of staging one
        // and leaving the rest out: the banner's Accept commits whatever the
        // editor staged, so anything not applied here is a row the operator
        // can see and cannot act on. New assets (`asset`) were left out of
        // that until now, so opening the editor on a queue of seven staged
        // one and stranded six.
        var batched = 0;
        try {
          final pending = ref.read(proposalStateProvider).proposals.toList();
          // Open on the page the review is about. A banner hands us one
          // proposal; land on its page so its batch is the one that stages,
          // rather than on whatever page sorts first -- otherwise the
          // proposal that opened the editor is the one left off it.
          _currentPage = _focusPageForProposals(pending) ?? _currentPage;
          // Stage only the proposals for the open page. Feeding the whole
          // queue to _applyAssetBatch regardless of page patched pages the
          // operator could not see and, worse, left the off-page ones neither
          // applied nor rejected -- pending forever from that view. The
          // off-page ones stay genuinely pending (not consumed) so they stage
          // when their own page is opened.
          final split = _partitionAssetProposals(pending, _currentPage);
          if (split.onPage.isNotEmpty) {
            batched = _applyAssetBatch(split.onPage);
            if (batched > 0) _noteOffPageProposals(split.elsewhere.length);
          }
        } catch (_) {
          // Provider unavailable in tests -- fall through to the single path.
        }
        if (batched == 0) _applyRoutedProposal(widget.proposalData);

        _updateCurrentJson();
        _savedJson =
            _isProposal ? '' : _currentJson; // Mark unsaved if proposal
      });
      // Only now: the banner's entry point routes by page_key, and until the
      // pages are loaded there is no page to route to.
      _publishReviewEntry();
    });
  }

  /// Tells the banner this editor is on screen and can take a proposal
  /// directly, so View and "Review all" do not have to beam at a route the
  /// operator is already on. See [ProposalReviewEntry] for why that beam
  /// cannot reach a mounted editor.
  void _publishReviewEntry() {
    // After this frame, for the same reason as [_publishProposalCallbacks]:
    // writing a provider while the tree is building trips riverpod's "tried
    // to modify a provider while the widget tree was building".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final slot = ref.read(proposalReviewProvider.notifier);
      slot.state = ProposalReviewEntry(
        route: proposalRoutes['asset']!,
        enter: _reviewProposal,
      );
      _reviewSlot = slot;
    });
  }

  /// Re-entered while already open: a View, "Review all" or "Open in Editor"
  /// tap on a banner hands this editor [data] while it is on screen.
  ///
  /// [initState] does NOT run a second time, and neither -- despite what it
  /// looks like -- does [didUpdateWidget]: the beam rebuilds the route's
  /// builder, but a page-based route keeps the page it already built (see
  /// [ProposalReviewEntry]). Without reacting here, a proposal that targets a
  /// page other than the open one never loads: the operator is sent to review
  /// it and lands on the page they were already on, with nothing staged.
  /// Route to the proposal's own page and stage its batch, the same thing a
  /// cold open does through initState.
  ///
  /// No leave guard in front of the switch. Every page lives in
  /// [_temporaryPages] and a save writes all of them, so moving [_currentPage]
  /// discards nothing -- which is why the Pages dialog's own page switching
  /// has never asked either. The guard is for leaving the editor, where the
  /// whole map is dropped.
  void _reviewProposal(String data) {
    _reviewData = data;
    List<PendingProposal> pending = const [];
    try {
      pending = ref.read(proposalStateProvider).proposals.toList();
    } catch (_) {
      // Provider unavailable in tests -- fall through to the single path.
    }
    // Land on the page the review is about: the new proposalData's page_key
    // wins, so "Review all" from a /boxes banner switches to /boxes even when
    // another page is open.
    final previousPage = _currentPage;
    final focus = _focusPageForProposals(pending);
    if (focus != null) _currentPage = focus;
    // Stage only that page's pending asset proposals; the off-page ones stay
    // pending for when their own page is opened. Idempotent -- ids already in
    // an open batch are skipped -- so re-entering does not double-stage.
    final split = _partitionAssetProposals(pending, _currentPage);
    var batched = 0;
    if (split.onPage.isNotEmpty) {
      batched = _applyAssetBatch(split.onPage);
      if (batched > 0) _noteOffPageProposals(split.elsewhere.length);
    }
    // A `page` proposal is not part of the asset batch; apply it directly, but
    // only when nothing is already staged -- _applyProposalData re-snapshots
    // the reject/revert baseline, which would clobber an open batch's.
    if (batched == 0 && !_isProposal) _applyRoutedProposal(data);
    if (batched > 0 || _isProposal) {
      _updateCurrentJson();
      _savedJson = ''; // Mark unsaved for the staged proposal.
    } else if (_currentPage == previousPage) {
      // Nothing staged and nothing moved. Leave [_savedJson] alone: rewriting
      // it to the current json would mark the operator's own unsaved edits
      // saved, and the leave guard would then let them walk away silently.
      return;
    }
    if (mounted) setState(() {});
  }

  /// The other way a fresh proposal could reach an already-built editor: the
  /// route rebuilding this widget with new [PageEditor.proposalData].
  ///
  /// Kept as a second door rather than the only one. It does not fire for the
  /// banner's beam today -- that is the whole of the bug [_reviewProposal]
  /// exists for -- but it is what would fire if the page were ever rebuilt
  /// rather than reused, and handing it the same body costs nothing.
  @override
  void didUpdateWidget(PageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final data = widget.proposalData;
    // Only a genuine change of proposal is a re-entry to act on; an unrelated
    // rebuild carries the same proposalData and must do nothing.
    if (data == null || data == oldWidget.proposalData) return;
    _reviewProposal(data);
  }

  /// Asked by the back arrow and the navigation bar before they leave.
  /// Nothing unsaved: go. Otherwise: Save and go, discard and go, or stay.
  Future<bool> _confirmLeave() async {
    if (!mounted || !_hasUnsavedChanges) return true;
    final choice = await showStandardDialog<_LeaveChoice>(
      context: context,
      title: 'Unsaved changes',
      icon: Icons.edit_note,
      barrierDismissible: false,
      builder: (_) => const Text(
          'This page has edits that are not saved. Leaving now discards them.'),
      actionsBuilder: (ctx) => [
        PaneAction(
          label: 'Stay',
          onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.stay),
        ),
        PaneAction.destructive(
          label: 'Discard',
          onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.discard),
        ),
        PaneAction.primary(
          label: 'Save and leave',
          icon: Icons.save,
          autofocus: true,
          onPressed: () => Navigator.of(ctx).pop(_LeaveChoice.save),
        ),
      ],
    );
    switch (choice) {
      case _LeaveChoice.save:
        await _saveToPrefs();
        return true;
      case _LeaveChoice.discard:
        return true;
      case _LeaveChoice.stay:
      case null:
        return false;
    }
  }

  @override
  void dispose() {
    LeaveGuard.clear(_confirmLeave);
    HardwareKeyboard.instance.removeHandler(_onShortcutKey);
    // Not awaited: awaiting a StreamSubscription.cancel() from State code
    // silently stalls widget tests, and a broadcast cancel has nothing to
    // flush anyway.
    _feedbackSub?.cancel();
    _feedbackSub = null;
    // The banner holds these closures over this State; left set they
    // would fire into a disposed State after navigating away -- nothing
    // saved, the proposals still pending, and an uncaught async error.
    //
    // After this frame, not during it: navigating away disposes us from
    // inside a build, and writing to a provider there trips riverpod's
    // "tried to modify a provider while the widget tree was building". Only
    // if the slot still holds our own closure -- an editor that replaced us
    // has already published its own, and clearing that would take the
    // banner's buttons away from a live batch.
    final commitSlot = _commitSlot;
    final discardSlot = _discardSlot;
    final reviewSlot = _reviewSlot;
    final commit = _saveToPrefs;
    final discard = _discardProposal;
    final review = _reviewProposal;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // `mounted` on the controllers, not on us: a frame later the whole
      // ProviderScope may be gone too -- the app shutting down, or a test
      // ending -- and reading a disposed StateController throws.
      if (commitSlot != null &&
          commitSlot.mounted &&
          commitSlot.state == commit) {
        commitSlot.state = null;
      }
      if (discardSlot != null &&
          discardSlot.mounted &&
          discardSlot.state == discard) {
        discardSlot.state = null;
      }
      // Left set, the banner would hand a proposal to a disposed State: the
      // switch would land on nothing and the operator would be told the
      // editor had moved when it is not even on screen. Same "only if it is
      // still ours" test as the two above -- a replacement editor has already
      // published its own entry.
      if (reviewSlot != null &&
          reviewSlot.mounted &&
          reviewSlot.state?.enter == review) {
        reviewSlot.state = null;
      }
    });
    _stopAutoScroll();
    // The pane lives in the root overlay, so nothing else tears it down when
    // the editor goes away (an MCP proposal can navigate out from under it).
    _configWatch?.cancel();
    _configWatch = null;
    _closeConfigPane();
    _closeBulkPane();
    // After the panes: closing one runs its `onClosed`, which reads this.
    _bulkRevision.dispose();
    _treeScrollController.dispose();
    _paletteSearchController.dispose();
    _shortcutFocus.dispose();
    super.dispose();
  }

  /// Parses proposal JSON and merges it into [_temporaryPages].
  ///
  /// For `_proposal_type: 'page'`: expects keys like `title`, `key`, `assets`,
  /// `mirroring_disabled`, `zoom_pan_disabled`. Creates or replaces a page
  /// entry.
  ///
  /// For `_proposal_type: 'asset'`: expects `key`, `title`, `children` (list
  /// of asset JSON). Adds assets to the page identified by `key`, or creates
  /// a new page.
  /// Applies every queued `asset` and `asset_update` proposal in one pass.
  ///
  /// Returns how many actually landed. Each one targets a different asset or
  /// child, so order does not matter and a failure to resolve one (a stale
  /// index, a create the registry cannot build) leaves the rest intact.
  ///
  /// One driver for both kinds. The applies differ -- a create builds new
  /// assets and appends them, an update patches one in place -- but the
  /// bookkeeping around them does not: snapshot the pages once, skip ids
  /// already staged or resolved, count what actually landed. `asset` used to
  /// have no batch at all, which is the whole of the bug below.
  int _applyAssetBatch(List<PendingProposal> proposals) {
    // An MCP client fires update_asset one call at a time, so a second wave
    // lands while the first is still staged. Extend the open batch instead of
    // restarting it: clearing _proposedAssets left only the newest asset
    // outlined -- eight bindings arrived, one yellow box showed -- and
    // re-snapshotting _preProposalPages over already-patched pages left
    // reject-all with no way back to the original.
    final extending = _preProposalPages != null;
    if (!extending) {
      _preProposalPages = PageManager.copyPages(_temporaryPages);
      _proposedAssets = {};
    }
    var applied = 0;
    for (final p in proposals) {
      if (_proposalIds.contains(p.id)) continue; // already staged
      if (_consumedProposalIds.contains(p.id)) continue; // already resolved
      try {
        final decoded = jsonDecode(p.proposalJson);
        if (decoded is! Map<String, dynamic>) continue;
        final type = decoded['_proposal_type'];
        final before = _proposedAssets.length;
        if (type == 'asset') {
          _applyAssetProposal(decoded);
        } else if (type == 'asset_update') {
          _applyUpdateProposal(decoded);
        } else {
          continue;
        }
        // Counted by what actually reached the canvas, not by what was
        // attempted: a proposal the registry could not build leaves its id
        // out of the batch and stays pending, rather than being marked
        // accepted against nothing.
        if (_proposedAssets.length > before) {
          _proposalIds.add(p.id);
          applied++;
        }
      } catch (e) {
        // A malformed proposal must not take the rest of the batch with it.
        // Inside the loop for that reason, and reported rather than
        // swallowed: a run of proposals missing required fields is how a
        // queue goes quiet with nothing to explain it.
        debugPrint('asset proposal ${p.id} could not be staged: $e');
      }
    }
    if (applied > 0) {
      _isProposal = true;
      _publishProposalCallbacks();
      final staged = _proposalIds.length;
      _proposalTitle = staged == 1 ? _proposalTitle : '$staged asset proposals';
    }
    return applied;
  }

  /// The `page_key` a proposal targets, or null when it names none.
  ///
  /// A null follows the open page -- the same `?? _currentPage` fallback the
  /// apply methods use -- so a proposal without a page_key always belongs to
  /// whatever page is showing.
  String? _proposalPageKey(PendingProposal p) {
    try {
      final decoded = jsonDecode(p.proposalJson);
      if (decoded is Map<String, dynamic>) {
        return decoded['page_key'] as String?;
      }
    } catch (_) {}
    return null;
  }

  /// Splits pending `asset`/`asset_update` proposals into the ones that belong
  /// on [page] and the ones that target another page.
  ///
  /// Staging is per page: an editor open on page A must not fold in a proposal
  /// for page B. Doing so patches a page the operator cannot see, and when the
  /// patch resolves against nothing on the open page it stages neither here
  /// nor there and stays pending with no way to act on it. The [elsewhere]
  /// ones are left pending so opening their page stages them there.
  ///
  /// "Another page" means a page that *exists*. An `asset` proposal naming a
  /// page_key no page has invents that page (see [_applyAssetProposal]), and
  /// deferring it to "when its page is opened" would defer it forever -- there
  /// is no such page to open. Those stage here, where the create can make one.
  ({List<PendingProposal> onPage, List<PendingProposal> elsewhere})
      _partitionAssetProposals(List<PendingProposal> all, String? page) {
    final onPage = <PendingProposal>[];
    final elsewhere = <PendingProposal>[];
    for (final p in all) {
      if (p.proposalType != 'asset' && p.proposalType != 'asset_update') {
        continue;
      }
      final key = _proposalPageKey(p);
      if (key == null || key == page || !_temporaryPages.containsKey(key)) {
        onPage.add(p);
      } else {
        elsewhere.add(p);
      }
    }
    return (onPage: onPage, elsewhere: elsewhere);
  }

  /// The page the editor should open on when launched with proposals pending:
  /// the one the operator is being asked to review.
  ///
  /// The banner passes the proposal it was raised for as [widget.proposalData]
  /// on a cold open, and as [_reviewData] when this editor was already up; its
  /// `page_key` wins, so opening from a `/boxes` banner lands on `/boxes` even
  /// when another page sorts ahead of it. Failing that, the first pending
  /// asset proposal's page. Null leaves the caller's default (the first page).
  String? _focusPageForProposals(List<PendingProposal> pending) {
    final data = _reviewData ?? widget.proposalData;
    if (data != null) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) {
          final key = decoded['page_key'] as String?;
          if (key != null && _temporaryPages.containsKey(key)) return key;
        }
      } catch (_) {}
    }
    for (final p in pending) {
      if (p.proposalType != 'asset' && p.proposalType != 'asset_update') {
        continue;
      }
      final key = _proposalPageKey(p);
      if (key != null && _temporaryPages.containsKey(key)) return key;
    }
    return null;
  }

  /// Appends a hint to the staged-batch title when proposals for other pages
  /// are still pending, so an operator who staged three of seven knows the
  /// other four are waiting on their own pages rather than lost.
  void _noteOffPageProposals(int count) {
    if (count <= 0) return;
    // Strip any note this already carries before adding one. A batch staged
    // one at a time leaves _proposalTitle untouched (see [_applyAssetBatch]),
    // so without this a second staging round would append a second suffix.
    final title = (_proposalTitle ?? 'AI Proposal')
        .replaceAll(RegExp(r' \(\+\d+ on other pages\)$'), '');
    _proposalTitle = '$title (+$count on other pages)';
  }

  /// Stages the pending asset proposals that belong to the open page.
  ///
  /// Called when the operator navigates to a page: any proposals waiting on it
  /// stage now, so switching pages is how the off-page proposals left pending
  /// at open get their turn. Idempotent -- [_applyAssetBatch] skips ids it has
  /// already staged -- so returning to a page is a no-op.
  void _stagePendingForCurrentPage() {
    final List<PendingProposal> pending;
    try {
      pending = ref.read(proposalStateProvider).proposals.toList();
    } catch (_) {
      return; // Provider unavailable in tests.
    }
    final split = _partitionAssetProposals(pending, _currentPage);
    if (split.onPage.isEmpty) return;
    final applied = _applyAssetBatch(split.onPage);
    if (applied == 0) return;
    _noteOffPageProposals(split.elsewhere.length);
    _updateCurrentJson();
    _savedJson = ''; // Mark unsaved for the staged proposal.
    if (mounted) setState(() {});
  }

  /// [_applyProposalData] for a proposal that came off the route, rather than
  /// out of [proposalStateProvider].
  ///
  /// Beamer keeps the payload on the location, so this editor is handed the
  /// same JSON on every later mount -- with state empty, because the proposal
  /// was accepted and dropped, which is exactly the condition the route
  /// fallback triggers on. Navigating back would otherwise stage a page edit
  /// that has already been saved and mark the editor unsaved over it, with
  /// nothing pending anywhere to accept or reject.
  ///
  /// The listener's path deliberately does not go through here: a proposal
  /// still sitting in state is live however familiar its JSON looks.
  void _applyRoutedProposal(String? proposalJson) {
    if (proposalJson == null) return;
    try {
      if (ref
          .read(proposalStateProvider.notifier)
          .isRoutePayloadResolved(proposalJson)) {
        return;
      }
    } catch (_) {
      // Provider unavailable in tests -- nothing says it was resolved.
    }
    _applyProposalData(proposalJson);
  }

  /// Records the route payload as resolved once the staged proposal is saved
  /// or reverted. See [_applyRoutedProposal].
  ///
  /// On the notifier, because the record has to outlive this State; through
  /// the captured container, because both callers can run after the editor
  /// has gone.
  void _markRoutePayloadResolved() {
    final json = widget.proposalData;
    if (json == null) return;
    final container = _container;
    try {
      final notifier = container != null
          ? container.read(proposalStateProvider.notifier)
          : ref.read(proposalStateProvider.notifier);
      notifier.markRoutePayloadResolved(json);
    } catch (_) {
      // Provider or ref gone -- nothing to record on.
    }
  }

  void _applyProposalData(String? proposalJson) {
    if (proposalJson == null) return;

    // Store pre-proposal snapshot for reject/revert.
    _preProposalPages = PageManager.copyPages(_temporaryPages);

    try {
      final Map<String, dynamic> proposal;
      final decoded = jsonDecode(proposalJson);
      if (decoded is Map<String, dynamic>) {
        proposal = decoded;
      } else {
        return;
      }

      final type = proposal['_proposal_type'] as String?;
      if (type == null) return;

      // Try to match proposal to universal state for ID tracking.
      try {
        final state = ref.read(proposalStateProvider);
        for (final p in state.proposals) {
          if (p.proposalJson == proposalJson) {
            _proposalIds.add(p.id);
            break;
          }
        }
      } catch (_) {}

      if (type == 'page') {
        _applyPageProposal(proposal);
      } else if (type == 'asset') {
        _applyAssetProposal(proposal);
      } else if (type == 'asset_update') {
        _applyUpdateProposal(proposal);
      }

      // Hand the banner a way to commit or revert what was just staged.
      //
      // Only the asset_update batch used to do this, so rejecting a `page` or
      // `asset` proposal from the banner fell back to marking the rows
      // rejected in the database -- the staged assets stayed on the page with
      // nothing left to explain them. _preProposalPages was captured above,
      // so the revert has always been possible; nobody was wired to ask for
      // it.
      if (_isProposal) {
        _publishProposalCallbacks();
      }
    } catch (_) {
      // Best-effort: if proposal JSON is malformed, ignore it.
    }
  }

  /// Hands the black banner the commit and discard actions for this batch,
  /// and takes the handles they will need once this editor is gone.
  ///
  /// Both staging paths ([_applyAssetBatch] and [_applyProposalData]) come
  /// through here. They used to carry a copy of this block each, which is a
  /// good way for one of them to miss the container capture below.
  void _publishProposalCallbacks() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final commitSlot = ref.read(proposalCommitProvider.notifier);
      commitSlot.state = _saveToPrefs;
      _commitSlot = commitSlot;
      final discardSlot = ref.read(proposalDiscardProvider.notifier);
      discardSlot.state = _discardProposal;
      _discardSlot = discardSlot;
      // Taken here, where `ref` and `context` are known good, because the two
      // callbacks above can be invoked long after this editor is gone.
      _container = ProviderScope.containerOf(context, listen: false);
    });
  }

  void _applyPageProposal(Map<String, dynamic> proposal) {
    final title = proposal['title'] as String? ?? 'AI Proposal';
    final key = proposal['key'] as String? ?? '/$title';
    final mirroringDisabled = proposal['mirroring_disabled'] as bool? ?? false;
    final zoomPanDisabled = proposal['zoom_pan_disabled'] as bool? ?? false;

    List<Asset> assets = [];
    if (proposal['assets'] is List) {
      final items = proposal['assets'] as List;
      // Try full parse first (works when JSON has all required fields).
      try {
        final parsed = AssetRegistry.parse({'assets': items});
        if (parsed.isNotEmpty) {
          assets = parsed;
        }
      } catch (_) {}
      // Fallback: create default assets by type name for minimal MCP JSON.
      if (assets.isEmpty) {
        for (final item in items) {
          if (item is! Map<String, dynamic>) continue;
          final assetName =
              item['asset_name'] as String? ?? item['asset_type'] as String?;
          if (assetName == null) continue;
          final asset = AssetRegistry.createDefaultAssetByName(assetName);
          if (asset == null) continue;
          if (item['key'] is String) {
            try {
              (asset as dynamic).key = item['key'] as String;
            } catch (_) {}
          }
          final label = item['title'] as String? ??
              item['label'] as String? ??
              item['text'] as String?;
          if (label != null) {
            asset.text = label;
            asset.textPos ??= TextPos.below;
          }
          if (item['coordinates'] is Map<String, dynamic>) {
            final c = item['coordinates'] as Map<String, dynamic>;
            asset.coordinates = Coordinates(
              x: (c['x'] as num?)?.toDouble() ?? 0.0,
              y: (c['y'] as num?)?.toDouble() ?? 0.0,
            );
          } else if (item['x'] is num || item['y'] is num) {
            asset.coordinates = Coordinates(
              x: (item['x'] as num?)?.toDouble() ?? 0.1,
              y: (item['y'] as num?)?.toDouble() ?? 0.1,
            );
          }
          assets.add(asset);
        }
      }
    }

    final page = AssetPage(
      menuItem: MenuItem(label: title, path: key, icon: Icons.auto_awesome),
      assets: assets,
      mirroringDisabled: mirroringDisabled,
      zoomPanDisabled: zoomPanDisabled,
    );

    _temporaryPages[key] = page;
    _currentPage = key;
    _isProposal = true;
    _proposalTitle = title;
    _proposedAssets = Set.of(assets);
  }

  void _applyAssetProposal(Map<String, dynamic> proposal) {
    final title = proposal['title'] as String? ?? 'AI Asset Proposal';
    // Use page_key to find the target page; fall back to current page.
    // proposal['key'] is the asset identifier, not a page key.
    final targetPage = proposal['page_key'] as String? ?? _currentPage;

    List<Asset> newAssets = [];
    for (final sourceKey in ['children', 'assets']) {
      if (proposal[sourceKey] is! List) continue;
      final items = proposal[sourceKey] as List;
      // First, try full parse (works when the JSON has all required fields).
      try {
        final parsed = AssetRegistry.parse({'assets': items});
        if (parsed.isNotEmpty) {
          newAssets.addAll(parsed);
          continue;
        }
      } catch (_) {}
      // Fallback: create default assets by type name and apply key/title/
      // coordinates from the proposal. This handles MCP proposals that only
      // provide minimal fields (asset_type, key, title).
      for (final item in items) {
        if (item is! Map<String, dynamic>) continue;
        final assetName =
            item['asset_name'] as String? ?? item['asset_type'] as String?;
        if (assetName == null) continue;
        final asset = AssetRegistry.createDefaultAssetByName(assetName);
        if (asset == null) continue;
        // Apply key — most asset types store it as a direct `key` field.
        if (item['key'] is String) {
          try {
            (asset as dynamic).key = item['key'] as String;
          } catch (_) {}
        }
        // Apply display text.
        final label = item['title'] as String? ?? item['text'] as String?;
        if (label != null) {
          asset.text = label;
          asset.textPos ??= TextPos.below;
        }
        // Apply coordinates.
        if (item['coordinates'] is Map<String, dynamic>) {
          final c = item['coordinates'] as Map<String, dynamic>;
          asset.coordinates = Coordinates(
            x: (c['x'] as num?)?.toDouble() ?? 0.0,
            y: (c['y'] as num?)?.toDouble() ?? 0.0,
          );
        } else if (item['x'] is num || item['y'] is num) {
          asset.coordinates = Coordinates(
            x: (item['x'] as num?)?.toDouble() ?? 0.1,
            y: (item['y'] as num?)?.toDouble() ?? 0.1,
          );
        }
        // Apply config overrides: merge LLM-provided config into the
        // default asset's JSON representation, then re-parse to get a
        // fully configured asset with all type-safe fields.
        final config = item['config'];
        if (config is Map<String, dynamic> && config.isNotEmpty) {
          try {
            final baseJson = asset.toJson();
            baseJson.addAll(config);
            // Ensure asset_name survives the merge so parse() finds it.
            baseJson[constAssetName] = assetName;
            final reparsed =
                AssetRegistry.parse({constAssetName: assetName, ...baseJson});
            if (reparsed.isNotEmpty) {
              newAssets.add(reparsed.first);
              continue;
            }
          } catch (e) {
            // Fall through to the default asset -- but say so. Silently
            // substituting a default is how a proposed LED column arrived
            // with the preview's two LEDs instead of the three it carried,
            // with nothing logged and nothing shown to the operator.
            // The logger, not stderr: in a windowed MSIX build stderr has
            // nowhere to go, so this warning -- the one that names the asset
            // whose override was dropped -- was written and then discarded on
            // every station. It cost three failed attempts to diagnose a
            // wrong-looking proposal on 2026-09-10.
            _log.w(
                'PageEditor: config override for "$assetName" could not be '
                'parsed, falling back to the default asset: $e');
          }
        }
        newAssets.add(asset);
      }
    }

    // Nothing the registry could build. Return before touching the pages or
    // raising [_isProposal]: a proposal that stages no asset used to claim
    // the editor anyway, and the listener's "already showing a proposal"
    // guard then blocked every proposal behind it -- with nothing to accept
    // and, on the branch below, an empty page invented for it.
    if (newAssets.isEmpty) return;

    // Added, not assigned. These are the outlines the canvas draws, and this
    // runs once per proposal in a batch: replacing the set left only the last
    // create outlined and lost every one before it.
    _proposedAssets.addAll(newAssets);

    if (targetPage != null && _temporaryPages.containsKey(targetPage)) {
      // Add assets to existing page.
      //
      // The asset list IS the draw order (page_view walks it front to back),
      // so appending always lands on top. A proposal may name the position it
      // wants instead -- a beacon belongs under the sensor it sits behind.
      final assets = _temporaryPages[targetPage]!.assets;
      final at = proposal['index'];
      if (at is int && at >= 0 && at <= assets.length) {
        assets.insertAll(at, newAssets);
      } else {
        assets.addAll(newAssets);
      }
      _currentPage = targetPage;
    } else {
      // Create a new page with the proposed assets.
      final pageKey = targetPage ?? '/$title';
      _temporaryPages[pageKey] = AssetPage(
        menuItem:
            MenuItem(label: title, path: pageKey, icon: Icons.auto_awesome),
        assets: newAssets,
        mirroringDisabled: false,
      );
      _currentPage = pageKey;
    }

    _isProposal = true;
    _proposalTitle = title;
  }

  void _applyUpdateProposal(Map<String, dynamic> proposal) {
    final targetPage = proposal['page_key'] as String? ?? _currentPage;
    final page = targetPage == null ? null : _temporaryPages[targetPage];
    final result = page == null
        ? const AssetUpdateResult.failure('page not found')
        : applyAssetUpdate(page.assets, proposal);

    final updated = result.updated;
    if (page == null || updated == null) {
      // The page is left untouched -- tell the operator why instead of
      // silently showing an editor with no diff.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('AI update proposal not applied: '
                  '${result.error}')),
        );
      });
      return;
    }

    page.assets[result.index] = updated;
    _currentPage = targetPage;
    _isProposal = true;
    _proposalTitle = updated.text ?? updated.runtimeType.toString();
    _proposedAssets = {..._proposedAssets, updated};
  }

  void _updateCurrentJson() {
    PageEditor.debugJsonEncodes++;
    _currentJson = jsonEncode(
        _temporaryPages.map((name, page) => MapEntry(name, page.toJson())));
    _currentJsonStale = false;
    // The open pane's change detector compares its asset against the last
    // time the editor looked at it, so every settled edit has to count as a
    // look. Without this a nudge or a drag of the very asset being configured
    // reads as a pane edit on the next watch tick, and pushes a second undo
    // entry for a change that already has one — leaving the operator's first
    // Ctrl+Z with nothing to do.
    final configAsset = _configAsset;
    if (configAsset != null) _configSnapshot = _assetSnapshot(configAsset);
 
    // The properties pane reads its rows straight off the assets, so any
    // settled edit — a nudge, a drag, an undo — leaves its fields showing
    // stale numbers until it is told to look again.
    if (_bulkPaneSelection != null) _bulkRevision.value++;
  }

  bool get _hasUnsavedChanges =>
      _currentJsonStale || _currentJson != _savedJson || _navOrderDirty;

  String _assetsToJson(List<Asset> theAssets) {
    return jsonEncode({
      'assets': theAssets.map((a) => a.toJson()).toList(),
    });
  }

  /// Reverts a staged proposal and marks every folded-in proposal rejected.
  ///
  /// Lives here rather than in the banner because the pre-proposal snapshot
  /// does: rejecting has to put the page back exactly as it was.
  Future<void> _discardProposal() async {
    // Through the container, never `ref`: this is the banner's reject, and by
    // the time it runs this editor may be disposed. `ref` throws then --
    // "Cannot use ref after the widget was disposed" -- before a single
    // proposal can be marked rejected.
    final container = _container;
    if (container == null) return;
    final notifier = container.read(proposalStateProvider.notifier);
    _consumedProposalIds.addAll(_proposalIds);
    for (final id in _proposalIds) {
      try {
        await notifier.rejectProposal(id);
      } catch (e) {
        // Reported rather than swallowed: a reject that silently fails to
        // land leaves the proposal pending, and it reappears on the next
        // load with the staged change already reverted.
        debugPrint('proposal $id could not be marked rejected: $e');
      }
    }
    // Before the `mounted` gate: a batch rejected after the operator
    // navigated away is still rejected, and its payload must not stage again.
    _markRoutePayloadResolved();
    if (!mounted) return;
    setState(() {
      if (_preProposalPages != null) {
        _temporaryPages = _preProposalPages!;
        _currentPage = _temporaryPages.keys.firstOrNull;
        _preProposalPages = null;
      }
      _isProposal = false;
      _proposalIds.clear();
      _proposedAssets = {};
      _updateCurrentJson();
      _savedJson = _currentJson;
    });
    _commitSlot?.state = null;
    _discardSlot?.state = null;
  }

  /// Un-stages staged proposals the operator rejected or dismissed on a
  /// surface that never asks this editor.
  ///
  /// [_discardProposal] handles the banner's whole-queue discard, but the
  /// banner's per-row reject and the chat batch card's reject-all go straight
  /// to [ProposalStateNotifier]: the proposal vanishes from the banner while
  /// the assets it staged stay in [_temporaryPages], and the operator's next
  /// save writes them exactly as an accept would have. That is how a rejected
  /// 35-asset proposal ended up persisted to its page (2026-09-02).
  ///
  /// The staged batch shares one pre-proposal snapshot, so the revert is
  /// all-or-nothing: restore [_preProposalPages], then restage whatever is
  /// still pending. A decision on one row of a batch therefore keeps the
  /// other rows staged -- rebuilt onto the restored snapshot rather than
  /// peeled out of the patched pages, which is the only way back an
  /// `asset_update` leaves.
  ///
  /// Decisions this editor made itself come through here too, a microtask
  /// after [_discardProposal] or [_saveToPrefs] reported them -- by then the
  /// ids are in [_consumedProposalIds] (both record them before reporting),
  /// so they are skipped below.
  void _onProposalFeedback(ProposalFeedback event) {
    if (!mounted) return;
    if (event.action != 'rejected' && event.action != 'dismissed') return;
    final undone = {
      for (final p in event.proposals)
        if (_proposalIds.contains(p.id) &&
            !_consumedProposalIds.contains(p.id))
          p.id,
    };
    if (undone.isEmpty) return;
    // Recorded before anything else, the same order [_discardProposal]
    // keeps: the restage below walks pending state, and a decided id must
    // never come back through it.
    _consumedProposalIds.addAll(undone);
    setState(() {
      if (_preProposalPages != null) {
        _temporaryPages = _preProposalPages!;
        _preProposalPages = null;
        if (_currentPage == null ||
            !_temporaryPages.containsKey(_currentPage)) {
          _currentPage = _temporaryPages.keys.firstOrNull;
        }
      }
      _isProposal = false;
      _proposalTitle = null;
      _proposalIds.clear();
      _proposedAssets = {};
      _updateCurrentJson();
      _savedJson = _currentJson;
    });
    _commitSlot?.state = null;
    _discardSlot?.state = null;
    // Survivors of a partial decision go back onto the canvas. By the time a
    // feedback event is delivered the decided rows are already out of state,
    // so pending is exactly what must stay staged.
    List<PendingProposal> pending = const [];
    try {
      pending = ref.read(proposalStateProvider).proposals.toList();
    } catch (_) {
      // Provider gone -- nothing left to restage.
    }
    final assetKinds = pending
        .where((p) =>
            p.proposalType == 'asset' || p.proposalType == 'asset_update')
        .toList();
    final split = _partitionAssetProposals(assetKinds, _currentPage);
    if (split.onPage.isNotEmpty && _applyAssetBatch(split.onPage) > 0) {
      setState(() {
        _updateCurrentJson();
        _savedJson = ''; // Still a staged proposal -- still unsaved.
      });
    } else if (!_isProposal) {
      final pageOnly =
          pending.where((p) => p.proposalType == 'page').toList();
      if (pageOnly.isNotEmpty) {
        setState(() {
          _applyProposalData(pageOnly.first.proposalJson);
          _updateCurrentJson();
          _savedJson = _isProposal ? '' : _currentJson;
        });
      }
    }
    // With nothing restaged, whatever payload this editor was opened with is
    // spent -- the same bookkeeping [_discardProposal] does, so a later
    // mount handed the same route data does not stage it again.
    if (!_isProposal) _markRoutePayloadResolved();
  }

  Future<void> _saveToPrefs() async {
    // Two callers, and only one of them has a live `ref`. The save button and
    // Ctrl+S run with this editor on screen; the banner's accept runs from a
    // notification that outlives it, after which `ref` throws. The container
    // is captured when the callbacks are published, so it is set exactly when
    // the banner path is possible and null for an ordinary save.
    final container = _container;
    final pageManager = container != null
        ? await container.read(pageManagerProvider.future)
        : await ref.read(pageManagerProvider.future);
    pageManager.pages = PageManager.copyPages(_temporaryPages);
    pageManager.topLevelOrder = List.of(_topLevelOrder);
    await pageManager.save();
    await _garbageCollectImages();
    if (container != null) {
      container.invalidate(pageManagerProvider);
    } else {
      ref.invalidate(pageManagerProvider);
    }

    // No `if (!mounted) return` in front of this any more. Accepting a batch
    // from the banner can navigate out from under this editor, and the guard
    // used to sit right here: the pages were written, the accept loop never
    // ran, every proposal stayed pending, and the same batch came back on the
    // next load. Only the rebuild at the end may depend on `mounted`.
    if (_isProposal && _proposalIds.isNotEmpty) {
      final notifier = container != null
          ? container.read(proposalStateProvider.notifier)
          : ref.read(proposalStateProvider.notifier);
      _consumedProposalIds.addAll(_proposalIds);
      for (final id in _proposalIds) {
        try {
          await notifier.acceptProposal(id);
        } catch (e) {
          // Reported rather than swallowed: an accept that silently fails to
          // land is indistinguishable from this whole bug -- pages written,
          // proposal still pending.
          debugPrint('proposal $id could not be marked accepted: $e');
        }
      }
    }

    // Whatever the route staged is now on disk, so the payload must stop
    // being stageable with it. Guarded, because this is the ordinary Save
    // button too, and an ordinary save resolves nothing.
    if (_isProposal) _markRoutePayloadResolved();

    _updateCurrentJson();
    _savedJson = _currentJson;
    _navOrderDirty = false;
    _isProposal = false; // Proposal accepted and saved.
    _proposalIds.clear();
    _proposedAssets = {};
    _preProposalPages = null;
    // Through the stored controllers, for the same reason as everything else
    // on this path.
    _commitSlot?.state = null;
    _discardSlot?.state = null;
    if (mounted) setState(() {});
  }

  /// Deletes stored image blobs nothing points at any more. Runs on save —
  /// the only moment deletions become permanent — and keeps anything the undo
  /// history or the copy buffer could still bring back.
  Future<void> _garbageCollectImages() async {
    try {
      // Through the captured container when there is one: this also runs on
      // the banner's accept, where `ref` is dead and the failure would land
      // in the swallow below, quietly leaving every orphan behind.
      final container = _container;
      final store = container != null
          ? await container.read(pageImageStoreProvider.future)
          : await ref.read(pageImageStoreProvider.future);
      final referenced = <String>{
        ...PageImageStore.referencedImageIds(
            _temporaryPages.map((name, page) => MapEntry(name, page.toJson()))),
        for (final snapshot in _undoHistory)
          ...PageImageStore.referencedImageIds(jsonDecode(snapshot.pagesJson)),
        if (_copiedAssets != null)
          ...PageImageStore.referencedImageIds(jsonDecode(_copiedAssets!)),
      };
      await store.removeUnreferenced(referenced);
    } catch (e) {
      // A failed cleanup must never break saving; orphans get another chance
      // on the next save. Still reported: a bare swallow here is how the
      // banner path went months without anyone noticing it never ran.
      debugPrint('image garbage collection skipped: $e');
    }
  }

  /// setState plus the dirty-check bookkeeping. One-shot edits re-encode the
  /// pages right away; per-tick edits (drag updates, arrow-key repeats) pass
  /// [deferJsonSync] and only raise [_currentJsonStale] — their settle point
  /// (pointer up, key up) runs the encode once for the whole gesture.
  void _updateState(VoidCallback fn, {bool deferJsonSync = false}) {
    setState(() {
      fn();
      if (deferJsonSync) {
        _currentJsonStale = true;
      } else {
        _updateCurrentJson();
      }
    });
  }

  void _saveToHistory() {
    // _currentJson tracks every settled edit (the same invariant the save
    // button's dirty check leans on), so it IS the snapshot — except mid
    // continuous gesture, where the sync was deferred and must run first.
    // Empty means "never encoded" (a valid encode is at least '{}').
    if (_currentJsonStale || _currentJson.isEmpty) _updateCurrentJson();
    _undoHistory.add(_EditorSnapshot(
      pagesJson: _currentJson,
      currentPage: _currentPage,
      topLevelOrder: List.of(_topLevelOrder),
      navOrderDirty: _navOrderDirty,
    ));
    if (_undoHistory.length > 50) {
      _undoHistory.removeAt(0);
    }
    // Whatever this entry is for, it is not the run of config-pane edits that
    // was folding into the last one, so the next pane edit opens its own.
    _configEditKeys = null;
  }

  void _handleUndo() {
    // An edit made in the pane within the last watch tick has not opened its
    // undo entry yet; without this the operator's Ctrl+Z would skip straight
    // past it and undo the action before it, leaving the pane edit applied.
    _syncConfigEdits();
    if (_undoHistory.isEmpty) return;
    final snapshot = _undoHistory.removeLast();

    // Where the assets the editor is holding sit in the page about to be
    // replaced. The pairing below turns those positions back into live
    // objects; taken now, while they are still on the canvas.
    final before = List<Asset>.of(assets);
    final configIndex =
        _configAsset == null ? -1 : before.indexOf(_configAsset!);
    final selectedIndices = [
      for (final asset in _selectedAssets)
        if (before.contains(asset)) before.indexOf(asset)
    ];
    final pageBefore = _currentPage;

    setState(() {
      _temporaryPages = PageManager.pagesFromJson(snapshot.pagesJson);
      _topLevelOrder = List.of(snapshot.topLevelOrder);
      _navOrderDirty = snapshot.navOrderDirty;
      // Back to the page the edit was made on — unless the undo is what
      // removed it, in which case anywhere real beats a page that is gone.
      _currentPage = _temporaryPages.containsKey(snapshot.currentPage)
          ? snapshot.currentPage
          : _temporaryPages.keys.firstOrNull;
      // The restored pages are fresh copies, so whatever was selected is now
      // dead instances: invisible on the canvas, yet a Delete on them would
      // push a snapshot while removing nothing — and the next undo would pop
      // that no-op and appear to do nothing. They are re-pointed at the assets
      // that came back, just below; anything with no counterpart stays gone.
      _selectedAssets = {};
      _updateCurrentJson();
    });

    final pairing = _currentPage == pageBefore ? _pairAcrossUndo(before) : null;
    if (pairing == null) {
      // A different page is showing now, so nothing the editor held is on it.
      _closeConfigPane();
      return;
    }
    setState(() {
      for (final index in selectedIndices) {
        final paired = pairing[index];
        if (paired != null) _selectedAssets.add(assets[paired]);
      }
    });
    if (_configAsset == null) return;
    final pairedConfig = configIndex < 0 ? null : pairing[configIndex];
    if (pairedConfig == null) {
      _closeConfigPane();
    } else {
      // Re-point rather than close: the operator is mid-configuration, and an
      // undo of one property is no reason to take the whole form away.
      final restored = assets[pairedConfig];
      _configAsset = null; // Keeps the swap from syncing the dead instance.
      _openConfigPane(restored);
    }
  }

  /// [matchAssetsAcrossUndo] over the live assets, or null if the assets will
  /// not serialize — in which case the editor keeps the old behaviour of
  /// dropping what it was holding.
  List<int?>? _pairAcrossUndo(List<Asset> before) {
    try {
      return matchAssetsAcrossUndo(
        [for (final asset in before) asset.toJson()],
        [for (final asset in assets) asset.toJson()],
      );
    } catch (_) {
      return null;
    }
  }

  /// Shuts the config pane, if one is open for this editor.
  void _closeConfigPane() {
    final asset = _configAsset;
    if (asset != null) closeSidePane(id: _configPaneId(asset));
  }

  /// Shuts the properties pane, if it is open.
  void _closeBulkPane() {
    if (_bulkPaneSelection != null) closeSidePane(id: _bulkPaneId);
  }

  /// The canvas shortcuts, registered on [HardwareKeyboard] for the editor's
  /// lifetime rather than hung off a Focus node. Focus wanders — into the
  /// root-overlay config pane, onto whatever button was clicked last — and
  /// every place it can wander to is a place a focus-scoped handler goes
  /// deaf. The guards below carve out the moments the shortcuts must yield.
  bool _onShortcutKey(KeyEvent event) {
    if (!mounted) return false;
    // A menu or dialog route on top owns the keyboard; Delete there must
    // never reach through to the canvas.
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    // Same for the free-floating pane dialogs, which are overlay entries
    // rather than routes.
    if (!FloatingDialogs.isEmpty) return false;
    // Don't intercept keys when a text field has focus — otherwise
    // backspace/delete edit the canvas selection, R rotates it and space
    // pans, all mid-keystroke. A focused text field's FocusNode attaches
    // to a Focus widget *inside* EditableText's build, so the focused
    // context's own widget is never EditableText — the EditableText is
    // found among its ancestors.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorStateOfType<EditableTextState>() !=
                null)) {
      return false;
    }
    // Space is held, not pressed: it is the only thing that turns a drag
    // on empty canvas from a marquee back into a canvas pan, so both
    // edges matter. KeyRepeatEvent arrives while it is down and must not
    // be read as a release.
    if (event.logicalKey == LogicalKeyboardKey.space) {
      final held = event is! KeyUpEvent;
      if (held != _isPanKeyHeld) {
        setState(() => _isPanKeyHeld = held);
      }
      return true;
    }
    // Arrow keys nudge the selection. Repeats count — holding the key keeps
    // moving — but only the initial press opens an undo entry, so a whole
    // press-and-hold walks back in a single Ctrl/Cmd+Z.
    final nudge = _arrowDirection(event.logicalKey);
    if (nudge != null &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        !_isModifierPressed(HardwareKeyboard.instance.logicalKeysPressed)) {
      return _nudgeSelection(nudge, saveHistory: event is KeyDownEvent);
    }
    // A press-and-hold deferred its JSON syncs (see _nudgeSelection); the
    // release is where it settles, so run the one encode that stands in for
    // all of them. The release itself stays unclaimed, as it always was.
    if (nudge != null && event is KeyUpEvent && _currentJsonStale) {
      setState(_updateCurrentJson);
    }
    if (event is KeyDownEvent) {
      if (_isModifierPressed(HardwareKeyboard.instance.logicalKeysPressed)) {
        if (event.logicalKey == LogicalKeyboardKey.keyZ) {
          _handleUndo();
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.keyC) {
          _handleCopy();
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.keyV) {
          _handlePaste();
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.keyS) {
          // The keyboard twin of the save FAB — same call, fire-and-forget,
          // since a key handler must answer synchronously.
          unawaited(_saveToPrefs());
          return true;
        }
      } else if (event.logicalKey == LogicalKeyboardKey.delete ||
          event.logicalKey == LogicalKeyboardKey.backspace) {
        _handleDelete();
        return true;
      } else if (event.logicalKey == LogicalKeyboardKey.keyR) {
        // Shift reverses it, the way the two menu entries pair up.
        _handleRotateShortcut(
          HardwareKeyboard.instance.isShiftPressed ? -90 : 90,
        );
        return true;
      }
    }
    return false;
  }

  bool _isModifierPressed(Set<LogicalKeyboardKey> keysPressed) {
    if (kIsWeb || Platform.isWindows || Platform.isLinux) {
      return keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
          keysPressed.contains(LogicalKeyboardKey.controlRight);
    } else if (Platform.isMacOS) {
      // Ctrl counts alongside Cmd: the same operator drives the plant's
      // Linux panels with Ctrl all day, and a Ctrl+Z that silently does
      // nothing on the Mac reads as "undo is broken", not "wrong key".
      return keysPressed.contains(LogicalKeyboardKey.metaLeft) ||
          keysPressed.contains(LogicalKeyboardKey.metaRight) ||
          keysPressed.contains(LogicalKeyboardKey.controlLeft) ||
          keysPressed.contains(LogicalKeyboardKey.controlRight);
    }
    return false;
  }

  void _handleAssetSelection(Asset asset, Set<LogicalKeyboardKey> keysPressed) {
    setState(() {
      if (_isModifierPressed(keysPressed)) {
        if (_selectedAssets.contains(asset)) {
          _selectedAssets.remove(asset);
        } else {
          _selectedAssets.add(asset);
        }
      } else {
        _selectedAssets = {asset};
      }
    });
  }

  /// The selected cable, when the selection is exactly one.
  ///
  /// Its handles are a different surface from the shared chrome, and showing
  /// them for a multi-selection would put corner handles on top of whatever
  /// else is selected.
  EtherCatLinkConfig? get _selectedLink {
    if (_selectedAssets.length != 1) return null;
    final only = _selectedAssets.first;
    return only is EtherCatLinkConfig ? only : null;
  }

  void _handleCopy() {
    if (_selectedAssets.isEmpty) return;
    _copyAssets(_selectedAssets.toList());
  }

  /// Backs both Ctrl/Cmd+C (the whole selection) and the context menu's Copy
  /// entry (the asset under the cursor, or the selection when it is in it).
  void _copyAssets(List<Asset> targets) {
    if (targets.isEmpty) return;
    _copiedAssets = _assetsToJson(targets);
    // Mirror onto the system clipboard, so paste can tell whether the user's
    // most recent copy was assets here or an image somewhere else.
    unawaited(EditorClipboard.instance.writeText(_copiedAssets!));
  }

  /// True when [text] is the asset JSON that [_handleCopy] puts on the system
  /// clipboard (from this or another editor window).
  bool _looksLikeAssetJson(String? text) {
    if (text == null || !text.contains(constAssetName)) return false;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return false;
      return AssetRegistry.parse(decoded).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// [at], in 0..1 canvas fractions, is where the context menu's "Paste here"
  /// drops the group — centred on the click. Ctrl/Cmd+V passes null and gets
  /// the classic slight offset from the source instead, so repeated pastes
  /// remain visibly distinct from what they copy.
  Future<void> _handlePaste({Offset? at}) async {
    final clipboard = EditorClipboard.instance;

    // The system clipboard reflects the user's latest copy: asset JSON when
    // they last copied in an editor, an image when they last copied one in a
    // browser or screenshot tool. Prefer whichever it holds; the in-memory
    // buffer is only a fallback for platforms with no clipboard access.
    String? assetJson;
    final text = await clipboard.readText();
    if (_looksLikeAssetJson(text)) {
      assetJson = text;
    } else {
      final imageBytes = await clipboard.readImage();
      if (imageBytes != null) {
        await _pasteImage(imageBytes, at: at);
        return;
      }
    }
    assetJson ??= _copiedAssets;
    if (assetJson == null || !mounted) return;
    final pasted = assetJson;

    _saveToHistory();
    final copiedAssets = AssetRegistry.parse(jsonDecode(pasted));
    reidentifyAssets(copiedAssets);
    setState(() {
      _selectedAssets.clear();

      if (at != null) {
        final placed = placeGroupAt(
          placements: _placements(copiedAssets),
          targetX: at.dx,
          targetY: at.dy,
          aspectRatio: _canvasAspectRatio(),
        );
        for (var i = 0; i < copiedAssets.length; i++) {
          copiedAssets[i].coordinates = Coordinates(
            x: placed[i].x,
            y: placed[i].y,
            angle: copiedAssets[i].coordinates.angle,
          );
        }
      } else {
        for (final asset in copiedAssets) {
          asset.coordinates = Coordinates(
            x: (asset.coordinates.x + 0.02).clamp(0.0, 1.0),
            y: (asset.coordinates.y + 0.02).clamp(0.0, 1.0),
            angle: asset.coordinates.angle,
          );
        }
      }
      for (final asset in copiedAssets) {
        assets.add(asset);
        _selectedAssets.add(asset);
      }
      _updateCurrentJson();
    });
    _retargetConfigPane(copiedAssets);
  }

  /// Re-points an open config pane at what a paste just produced.
  ///
  /// An operator pasting with the pane up is duplicating the asset they are
  /// configuring; the asset they want to edit next is the copy, not the
  /// source. Only a lone pasted asset re-points the pane — a group paste has
  /// no single asset for the pane to show, so it stays where it was.
  void _retargetConfigPane(List<Asset> pasted) {
    if (_configAsset == null || pasted.length != 1) return;
    _openConfigPane(pasted.single);
  }

  /// The live canvas's width / height, or 16:9 before the first layout.
  double _canvasAspectRatio() {
    final constraints = _canvasConstraints;
    return constraints == null || constraints.maxHeight <= 0
        ? 16 / 9
        : constraints.maxWidth / constraints.maxHeight;
  }

  /// Drops a pasted clipboard image onto the canvas as a new [ImageConfig],
  /// sized so the image keeps its shape at a quarter of the canvas width —
  /// centred on [at] when the paste came from the context menu, on the canvas
  /// itself when it came from Ctrl/Cmd+V.
  Future<void> _pasteImage(Uint8List bytes, {Offset? at}) async {
    try {
      final store = await ref.read(pageImageStoreProvider.future);
      final ingest = await ingestPageImage(store, bytes);
      // The id is content-derived: a re-pasted image may reuse an id whose
      // provider cached "gone" after garbage collection.
      ref.invalidate(pageImageBytesProvider(ingest.id));
      if (!mounted) return;

      final canvasAspect = _canvasAspectRatio();
      const widthFrac = 0.25;
      final heightFrac =
          (widthFrac * canvasAspect / ingest.aspectRatio).clamp(0.02, 0.9);

      var coordinates = Coordinates(x: 0.5, y: 0.5);
      if (at != null) {
        // The same pull-back-on-canvas rule as pasting assets, so a paste
        // near an edge lands flush against it instead of half off-screen.
        final placed = placeGroupAt(
          placements: [
            AssetPlacement(
                x: at.dx, y: at.dy, width: widthFrac, height: heightFrac),
          ],
          targetX: at.dx,
          targetY: at.dy,
          aspectRatio: canvasAspect,
        ).single;
        coordinates = Coordinates(x: placed.x, y: placed.y);
      }

      final asset = ImageConfig()
        ..applyIngest(ingest)
        ..size = RelativeSize(width: widthFrac, height: heightFrac)
        ..coordinates = coordinates;

      _saveToHistory();
      setState(() {
        assets.add(asset);
        _selectedAssets
          ..clear()
          ..add(asset);
        _updateCurrentJson();
      });
      _retargetConfigPane([asset]);
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _handleDelete() => _deleteAssets(_selectedAssets.toList());

  /// Removes [targets] from the page. Backs both the Delete/Backspace keys
  /// (whole selection) and the context menu's Delete entry (the asset under
  /// the cursor, or the selection when it is part of one).
  void _deleteAssets(List<Asset> targets) {
    if (targets.isEmpty) return;

    // The pane would otherwise stay up over an asset that no longer exists
    // until the next `_syncConfigEdits` tick noticed and shut it.
    final configAsset = _configAsset;
    if (configAsset != null && targets.contains(configAsset)) {
      closeSidePane(id: _configPaneId(configAsset));
    }

    _saveToHistory();
    setState(() {
      assets.removeWhere(targets.contains);
      _selectedAssets.removeAll(targets);
      _updateCurrentJson();
    });
  }

  /// Rotates the current selection a quarter turn from the keyboard.
  ///
  /// The same group rotation the context menu offers — a single selected asset
  /// spins in place, several turn as one rigid group. Silently does nothing
  /// with an empty selection, so the key is harmless when nothing is picked.
  void _handleRotateShortcut(double degrees) {
    final constraints = _canvasConstraints;
    if (constraints == null || _selectedAssets.isEmpty) return;
    _rotateAssets(_selectedAssets.toList(), degrees, constraints);
  }

  /// One arrow press moves this many canvas pixels; Shift multiplies by ten.
  /// The arrows are the precision tool the mouse isn't, so the base step is
  /// the smallest one that shows.
  static const double _nudgeStepPx = 1.0;
  static const double _nudgeShiftFactor = 10.0;

  /// Screen-space direction of an arrow key, or null for any other key.
  static Offset? _arrowDirection(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) return const Offset(-1, 0);
    if (key == LogicalKeyboardKey.arrowRight) return const Offset(1, 0);
    if (key == LogicalKeyboardKey.arrowUp) return const Offset(0, -1);
    if (key == LogicalKeyboardKey.arrowDown) return const Offset(0, 1);
    return null;
  }

  /// One keyboard nudge of the whole selection, clamped to the canvas like a
  /// drag. Unlike a drag there is no rotated gesture frame to project out of:
  /// [direction] is already in canvas space, so a screen-right press moves
  /// screen-right whatever the assets' angles.
  ///
  /// False — leaving the key unclaimed — with nothing selected or no canvas
  /// laid out, so the arrows keep whatever meaning the rest of the app gives
  /// them.
  bool _nudgeSelection(Offset direction, {required bool saveHistory}) {
    final constraints = _canvasConstraints;
    if (constraints == null || _selectedAssets.isEmpty) return false;
    final step = HardwareKeyboard.instance.isShiftPressed
        ? _nudgeStepPx * _nudgeShiftFactor
        : _nudgeStepPx;
    if (saveHistory) _saveToHistory();
    // Key repeats arrive per frame while the arrow is held; the JSON sync
    // waits for the key-up in _onShortcutKey.
    _updateState(deferJsonSync: true, () {
      for (final asset in _selectedAssets) {
        asset.coordinates = Coordinates(
          x: (asset.coordinates.x + direction.dx * step / constraints.maxWidth)
              .clamp(0.0, 1.0),
          y: (asset.coordinates.y + direction.dy * step / constraints.maxHeight)
              .clamp(0.0, 1.0),
          angle: asset.coordinates.angle,
        );
      }
    });
    return true;
  }

  /// Menu values for the editing actions; AI entries use their own list index,
  /// so these sit outside that range.
  static const int _sendToBackAction = -1;
  static const int _rotateClockwiseAction = -2;
  static const int _rotateCounterClockwiseAction = -3;
  static const int _alignHorizontalAction = -4;
  static const int _alignVerticalAction = -5;
  static const int _editAction = -6;
  static const int _mirrorHorizontalAction = -7;
  static const int _mirrorVerticalAction = -8;
  static const int _bringToFrontAction = -9;
  static const int _copyAction = -10;
  static const int _pasteAction = -11;
  static const int _deleteAction = -12;

  /// Assets a canvas action applies to: the whole selection when the asset
  /// acted on is part of it, otherwise just that asset. Mirrors [_moveAsset].
  List<Asset> _actionTargets(Asset asset) =>
      _selectedAssets.contains(asset) ? _selectedAssets.toList() : [asset];

  /// False when [targets] already sit at the bottom, so the menu entry can be
  /// disabled rather than pushing a no-op onto the undo history.
  bool _canSendToBack(List<Asset> targets) =>
      !isAlreadyAtBack(assets, targets.toSet());

  /// False when [targets] already sit on top, so the menu entry can be
  /// disabled rather than pushing a no-op onto the undo history.
  bool _canBringToFront(List<Asset> targets) =>
      !isAlreadyAtFront(assets, targets.toSet());

  /// Moves [targets] beneath every other asset on the page.
  void _sendToBack(List<Asset> targets) {
    final moving = targets.toSet();
    if (isAlreadyAtBack(assets, moving)) return;
    _applyOrder(sendToBackOrder(assets, moving));
  }

  /// Moves [targets] on top of every other asset on the page.
  void _bringToFront(List<Asset> targets) {
    final moving = targets.toSet();
    if (isAlreadyAtFront(assets, moving)) return;
    _applyOrder(bringToFrontOrder(assets, moving));
  }

  void _applyOrder(List<Asset> reordered) {
    _saveToHistory();
    setState(() {
      // Mutate in place: AssetPage holds a reference to this same list.
      assets
        ..clear()
        ..addAll(reordered);
      _updateCurrentJson();
    });
  }

  /// [targets] as placements, for the geometry helpers.
  List<AssetPlacement> _placements(List<Asset> targets) => [
        for (final asset in targets)
          AssetPlacement(
            x: asset.coordinates.x,
            y: asset.coordinates.y,
            width: asset.size.width,
            height: asset.size.height,
            angle: asset.coordinates.angle,
          ),
      ];

  /// Writes [placements] back onto [targets], which must line up positionally.
  void _applyPlacements(List<Asset> targets, List<AssetPlacement> placements) {
    _saveToHistory();
    _updateState(() {
      for (var i = 0; i < targets.length; i++) {
        targets[i].coordinates = Coordinates(
          x: placements[i].x,
          y: placements[i].y,
          angle: placements[i].angle,
        );
      }
    });
  }

  /// False when [targets] already sit on one line along [axis], so the menu
  /// entry can be disabled. Mirrors [_canSendToBack].
  bool _canAlign(List<Asset> targets, AlignAxis axis) =>
      !isAlreadyAligned(_placements(targets), axis);

  /// Lines [targets] up on [axis], centre points onto the selection's middle.
  void _alignAssets(List<Asset> targets, AlignAxis axis) {
    final placements = _placements(targets);
    if (isAlreadyAligned(placements, axis)) return;

    _applyPlacements(targets, alignGroup(placements: placements, axis: axis));
  }

  /// Rotates [targets] a quarter turn as one rigid group about the centre of
  /// their combined bounding box. A single asset is just the degenerate case:
  /// its own centre is the group centre, so it spins in place.
  ///
  /// [constraints] supplies the canvas aspect ratio, without which a rotation
  /// of the normalized coordinates would shear the group. See [rotateGroup].
  void _rotateAssets(
    List<Asset> targets,
    double degrees,
    BoxConstraints constraints,
  ) {
    if (targets.isEmpty) return;

    _applyPlacements(
      targets,
      rotateGroup(
        placements: _placements(targets),
        degrees: degrees,
        aspectRatio: constraints.maxWidth / constraints.maxHeight,
      ),
    );
  }

  /// Flips [targets] about the centre of their combined bounding box.
  ///
  /// [constraints] supplies the canvas aspect ratio, for the same reason
  /// [_rotateAssets] needs it. See [mirrorGroup].
  void _mirrorAssets(
    List<Asset> targets,
    MirrorAxis axis,
    BoxConstraints constraints,
  ) {
    if (targets.isEmpty) return;

    _applyPlacements(
      targets,
      mirrorGroup(
        placements: _placements(targets),
        axis: axis,
        aspectRatio: constraints.maxWidth / constraints.maxHeight,
      ),
    );
  }

  /// Right-click menu for an asset on the canvas.
  ///
  /// Editing actions are always available; the AI entries are appended only
  /// when MCP chat is up, preserving what the AI-only menu used to offer.
  ///
  /// [constraints] are the canvas's, needed by the rotate entries.
  /// [pasteTarget] is the click point in 0..1 canvas fractions, where the
  /// Paste entry drops its group.
  Future<void> _showAssetContextMenu(
    Asset asset,
    Offset globalPosition,
    BoxConstraints constraints,
    Offset pasteTarget,
  ) async {
    final aiItems = kChatEnabled
        ? buildEditorAssetMenuItems(asset)
        : const <AiMenuItem>[];

    final targets = _actionTargets(asset);
    final canSendToBack = _canSendToBack(targets);
    final canBringToFront = _canBringToFront(targets);
    final canAlignHorizontal = _canAlign(targets, AlignAxis.horizontal);
    final canAlignVertical = _canAlign(targets, AlignAxis.vertical);

    final choice = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        // First, and on its own: this is how the configuration editor is
        // reached now that a tap selects instead of opening it.
        //
        // It follows the same targets rule as the entries below, but opens a
        // different pane for each case. One asset gets its own `configure()`
        // form — the complete one, with the key pickers and the device
        // specifics. A selection gets the properties grid, which offers only
        // what the selected assets have in common but writes to all of them
        // at once (see [_openBulkEditPane]).
        PopupMenuItem<int>(
          value: _editAction,
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: Text(
                targets.length > 1 ? 'Edit ${targets.length} assets' : 'Edit'),
            dense: true,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: _copyAction,
          child: ListTile(
            leading: const Icon(Icons.copy),
            title: Text(
                targets.length > 1 ? 'Copy ${targets.length} assets' : 'Copy'),
            dense: true,
          ),
        ),
        // Always enabled: whether there is anything to paste can live on the
        // system clipboard (asset JSON or an image from another window), which
        // cannot be inspected synchronously. An empty paste is a no-op.
        PopupMenuItem<int>(
          value: _pasteAction,
          child: const ListTile(
            leading: Icon(Icons.content_paste),
            title: Text('Paste here'),
            dense: true,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: _rotateClockwiseAction,
          child: ListTile(
            leading: const Icon(Icons.rotate_right),
            title: Text(targets.length > 1
                ? 'Rotate ${targets.length} assets 90° clockwise'
                : 'Rotate 90° clockwise'),
            dense: true,
          ),
        ),
        PopupMenuItem<int>(
          value: _rotateCounterClockwiseAction,
          child: ListTile(
            leading: const Icon(Icons.rotate_left),
            title: Text(targets.length > 1
                ? 'Rotate ${targets.length} assets 90° counter-clockwise'
                : 'Rotate 90° counter-clockwise'),
            dense: true,
          ),
        ),
        // Named for the direction things move, not the line they reflect
        // about: "horizontally" swaps left for right. Matches how a drawing
        // tool's Flip Horizontal reads, and how the rotate pair above it does.
        PopupMenuItem<int>(
          value: _mirrorHorizontalAction,
          child: ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(targets.length > 1
                ? 'Mirror ${targets.length} assets horizontally'
                : 'Mirror horizontally'),
            dense: true,
          ),
        ),
        PopupMenuItem<int>(
          value: _mirrorVerticalAction,
          child: ListTile(
            leading: const Icon(Icons.swap_vert),
            title: Text(targets.length > 1
                ? 'Mirror ${targets.length} assets vertically'
                : 'Mirror vertically'),
            dense: true,
          ),
        ),
        // The icon names read backwards: `align_vertical_center` draws a
        // horizontal reference line, which is what lining assets up into a
        // row looks like. Pair each entry with the line it produces, not with
        // the word in the icon name.
        PopupMenuItem<int>(
          value: _alignHorizontalAction,
          enabled: canAlignHorizontal,
          child: ListTile(
            leading: const Icon(Icons.align_vertical_center),
            title: Text(targets.length > 1
                ? 'Align ${targets.length} assets horizontally'
                : 'Align horizontally'),
            dense: true,
            enabled: canAlignHorizontal,
          ),
        ),
        PopupMenuItem<int>(
          value: _alignVerticalAction,
          enabled: canAlignVertical,
          child: ListTile(
            leading: const Icon(Icons.align_horizontal_center),
            title: Text(targets.length > 1
                ? 'Align ${targets.length} assets vertically'
                : 'Align vertically'),
            dense: true,
            enabled: canAlignVertical,
          ),
        ),
        PopupMenuItem<int>(
          value: _bringToFrontAction,
          enabled: canBringToFront,
          child: ListTile(
            leading: const Icon(Icons.flip_to_front),
            title: Text(targets.length > 1
                ? 'Bring ${targets.length} assets to front'
                : 'Bring to front'),
            dense: true,
            enabled: canBringToFront,
          ),
        ),
        PopupMenuItem<int>(
          value: _sendToBackAction,
          enabled: canSendToBack,
          child: ListTile(
            leading: const Icon(Icons.flip_to_back),
            title: Text(targets.length > 1
                ? 'Send ${targets.length} assets to back'
                : 'Send to back'),
            dense: true,
            enabled: canSendToBack,
          ),
        ),
        // Set off from the layout actions above: everything else rearranges,
        // this one destroys. Same targets rule though — the selection when
        // the clicked asset is in it, otherwise just that asset.
        const PopupMenuDivider(),
        PopupMenuItem<int>(
          value: _deleteAction,
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(targets.length > 1
                ? 'Delete ${targets.length} assets'
                : 'Delete'),
            dense: true,
          ),
        ),
        if (aiItems.isNotEmpty) const PopupMenuDivider(),
        for (var i = 0; i < aiItems.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: ListTile(
              leading: Icon(aiItems[i].icon),
              title: Text(aiItems[i].label),
              dense: true,
            ),
          ),
      ],
    );

    if (choice == null) return;
    // The editor can be torn down while the menu is open — proposal events
    // arriving over MCP navigate on their own — and both branches below touch
    // State (setState / ref) that is invalid after dispose.
    if (!mounted) return;

    if (choice == _editAction) {
      if (targets.length > 1) {
        _openBulkEditPane(targets);
      } else if (!identical(_configAsset, asset)) {
        // `_openConfigPane` toggles, which from a menu entry reading "Edit"
        // would read as the pane refusing to open. Already showing this asset
        // is already the wanted end state.
        _openConfigPane(asset);
      }
    } else if (choice == _sendToBackAction) {
      _sendToBack(targets);
    } else if (choice == _bringToFrontAction) {
      _bringToFront(targets);
    } else if (choice == _rotateClockwiseAction) {
      _rotateAssets(targets, 90, constraints);
    } else if (choice == _rotateCounterClockwiseAction) {
      _rotateAssets(targets, -90, constraints);
    } else if (choice == _mirrorHorizontalAction) {
      _mirrorAssets(targets, MirrorAxis.horizontal, constraints);
    } else if (choice == _mirrorVerticalAction) {
      _mirrorAssets(targets, MirrorAxis.vertical, constraints);
    } else if (choice == _alignHorizontalAction) {
      _alignAssets(targets, AlignAxis.horizontal);
    } else if (choice == _alignVerticalAction) {
      _alignAssets(targets, AlignAxis.vertical);
    } else if (choice == _deleteAction) {
      _deleteAssets(targets);
    } else if (choice == _copyAction) {
      _copyAssets(targets);
    } else if (choice == _pasteAction) {
      await _handlePaste(at: pasteTarget);
    } else if (kChatEnabled) {
      await AiContextAction.runMenuItem(ref: ref, item: aiItems[choice]);
    }
  }

  /// Right-click menu for empty canvas. One entry so far: paste, centred on
  /// the click — the natural counterpart of Copy on the asset menu.
  Future<void> _showCanvasContextMenu(
    Offset globalPosition,
    Offset pasteTarget,
  ) async {
    final choice = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        // Enabled unconditionally, same reasoning as the asset menu's entry.
        const PopupMenuItem<int>(
          value: _pasteAction,
          child: ListTile(
            leading: Icon(Icons.content_paste),
            title: Text('Paste here'),
            dense: true,
          ),
        ),
      ],
    );
    if (choice != _pasteAction || !mounted) return;
    await _handlePaste(at: pasteTarget);
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the properties pane on the live selection; a no-op when it is
    // closed, which is the usual case.
    _refreshBulkPane();
    // Reactively watch for new page/asset proposals arriving via MCP.
    ref.listen<ProposalState>(proposalStateProvider, (prev, next) {
      final pageProposals = next.proposals.where((p) =>
          p.proposalType == 'page' ||
          p.proposalType == 'asset' ||
          // asset_update arrives from the update_asset MCP tool. Without it
          // the proposal reaches ProposalState but the editor never picks it
          // up, so the operator sees nothing to save.
          p.proposalType == 'asset_update');
      if (pageProposals.isEmpty) return;
      // Stage only what belongs on the open page. A proposal for another page
      // stays pending and stages when that page is opened, rather than being
      // folded invisibly into a page the operator cannot see -- which is how a
      // cross-page batch stranded the off-page proposals with nothing to act
      // on. The off-page count still shows in the title, below.
      final split = _partitionAssetProposals(pageProposals.toList(),
          _currentPage);
      final assetProposals = split.onPage;
      final pageOnly = pageProposals
          .where((p) => p.proposalType == 'page')
          .toList();
      if (assetProposals.isNotEmpty) {
        // Whole queue at once -- one review, one save. Safe to re-enter while
        // a batch is already staged: ids already applied are skipped, so a
        // proposal arriving after the first joins the batch rather than being
        // swallowed by an "already showing a proposal" guard.
        //
        // `asset` used to fall through to the single-apply branch below,
        // where only pageProposals.first was ever applied. That set
        // _isProposal, and every proposal behind it hit the guard: seven new
        // assets staged one, "Accept all" removed a single row, and "Review
        // all" then did nothing at all, because nothing further was ever
        // staged and the commit slot stayed null. Batching them is the same
        // reasoning asset_update already carried: the banner's Accept
        // commits whatever this editor staged, so a proposal left unstaged
        // is a row the operator can see and cannot act on.
        if (_applyAssetBatch(assetProposals) > 0) {
          _noteOffPageProposals(split.elsewhere.length);
        }
      } else if (pageOnly.isNotEmpty) {
        // Only `page` reaches this. It replaces or creates a whole page, so
        // folding a run of them together has no defined result; a run of
        // assets appended to a page does.
        if (_isProposal) return; // Already showing a proposal.
        _applyProposalData(pageOnly.first.proposalJson);
      } else {
        // Every asset proposal that arrived targets another page. Leave them
        // pending -- do not stage them into the open page -- so they surface
        // when their own page is opened.
        return;
      }
      if (_isProposal) {
        _updateCurrentJson();
        _savedJson = ''; // Mark unsaved for proposal.
        setState(() {});
      }
    });

    return Focus(
      focusNode: _shortcutFocus,
      autofocus: true,
      // A window switch or a click into the palette can swallow the key up,
      // which would otherwise leave the canvas stuck in pan.
      onFocusChange: (hasFocus) {
        if (!hasFocus && _isPanKeyHeld) {
          setState(() => _isPanKeyHeld = false);
        }
      },
      child: BaseScaffold(
        title: _isProposal ? 'Page Editor — AI Proposal' : 'Page Editor',
        body: Column(
          children: [
            Expanded(
                child: Listener(
                    // Any click on the canvas re-arms the shortcuts. Selecting an
                    // asset and pressing Ctrl/Cmd+C must work no matter what held
                    // keyboard focus before — the config pane's fields being the
                    // case that never heals on its own: the pane lives in the root
                    // overlay, so as long as it keeps focus, key events never even
                    // reach this page's Focus subtree. Raw pointer-down, not a tap:
                    // it precedes the gesture arena, so a text field clicked inside
                    // the palette still wins focus back on the tap itself.
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (_) {
                      if (!_shortcutFocus.hasPrimaryFocus) {
                        _shortcutFocus.requestFocus();
                      }
                    },
                    // The open config pane docks over the right edge of the
                    // screen; when it would cover the very asset being edited
                    // (and only then), the inset re-fits the whole canvas —
                    // page, chrome, selection, all of it — beside the pane.
                    child: SidePaneInset(
                        child: ZoomableCanvas(
                      scaleEnabled: !_showPalette,
                      panEnabled: _isPanKeyHeld,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Stashed for the keyboard handler, which is above this
                          // builder and cannot see the canvas box. Plain assignment:
                          // calling setState during build is not allowed, and nothing
                          // here needs a repaint — the next rotate simply reads it.
                          _canvasConstraints = constraints;
                          _canvasContext = context;
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              Container(
                                color: Theme.of(context).colorScheme.surface,
                              ),
                              // The only feedback that the held pan key has
                              // changed what a drag will do. A MouseRegion
                              // only tracks hover — it joins no gesture arena
                              // — so it can sit in the stack rather than
                              // wrapping the canvas and re-indenting it.
                              if (_isPanKeyHeld)
                                const Positioned.fill(
                                  child: MouseRegion(
                                      cursor: SystemMouseCursors.grab),
                                ),
                              DragTarget<Type>(
                                onAcceptWithDetails: (details) {
                                  final RenderBox box =
                                      context.findRenderObject() as RenderBox;
                                  final localPosition =
                                      box.globalToLocal(details.offset);

                                  final relativeX =
                                      (localPosition.dx / box.size.width)
                                          .clamp(0.0, 1.0);
                                  final relativeY =
                                      (localPosition.dy / box.size.height)
                                          .clamp(0.0, 1.0);

                                  final newAsset =
                                      AssetRegistry.createDefaultAsset(
                                          details.data);
                                  _saveToHistory();
                                  setState(() {
                                    newAsset.coordinates =
                                        Coordinates(x: relativeX, y: relativeY);
                                    assets.add(newAsset);
                                    _updateCurrentJson();
                                  });
                                },
                                builder:
                                    (context, candidateData, rejectedData) {
                                  return AssetStack(
                                    assets: assets,
                                    constraints: constraints,
                                    // A tap selects, always. Configuring used to be
                                    // what a tap did, in the mode where selecting was
                                    // not; with one mode there is room for only one
                                    // meaning, and the config pane is reachable from
                                    // the right-click menu instead. The pane is not
                                    // modal, so it can follow the selection: with one
                                    // already open, selecting another asset re-points
                                    // it rather than leaving stale config on screen.
                                    onTap: (asset) {
                                      final keys = HardwareKeyboard
                                          .instance.logicalKeysPressed;
                                      _handleAssetSelection(asset, keys);
                                      if (_configAsset != null &&
                                          !identical(_configAsset, asset) &&
                                          !_isModifierPressed(keys)) {
                                        _openConfigPane(asset);
                                      }
                                    },
                                    // The pointer-first route to the config pane; the
                                    // right-click menu's "Edit" stays as the
                                    // discoverable one. A double tap swallows both of
                                    // its single taps, so selection has to happen
                                    // here too — plainly, since reaching for a double
                                    // click says "just this one".
                                    onDoubleTap: (asset) {
                                      setState(() => _selectedAssets = {asset});
                                      if (!identical(_configAsset, asset)) {
                                        _openConfigPane(asset);
                                      }
                                    },
                                    onPanUpdate: (asset, details) {
                                      _moveAsset(asset, details, constraints);
                                    },
                                    onPanStart: (asset, details) {
                                      // Claims the drag for the asset so the marquee
                                      // listener below stands down for its duration.
                                      _isDraggingAsset = true;
                                      _saveToHistory();
                                    },
                                    onSecondaryTap: (asset, globalPosition) {
                                      final box = context.findRenderObject()
                                          as RenderBox;
                                      final local =
                                          box.globalToLocal(globalPosition);
                                      _showAssetContextMenu(
                                        asset,
                                        globalPosition,
                                        constraints,
                                        Offset(
                                          (local.dx / constraints.maxWidth)
                                              .clamp(0.0, 1.0),
                                          (local.dy / constraints.maxHeight)
                                              .clamp(0.0, 1.0),
                                        ),
                                      );
                                    },
                                    absorb: true,
                                    selectedAssets: _selectedAssets,
                                    proposedAssets: _proposedAssets,
                                    mirroringDisabled:
                                        _temporaryPages[_currentPage]
                                                ?.mirroringDisabled ??
                                            false,
                                  );
                                },
                              ),
                              // Always live now, rather than only in a select mode.
                              // It stands down while the pan key is held, which is the
                              // one gesture it would otherwise take over.
                              if (!_isPanKeyHeld)
                                Listener(
                                  behavior: HitTestBehavior.translucent,
                                  onPointerDown: (pointerEvent) {
                                    // A middle-button drag is a canvas pan —
                                    // ZoomableCanvas claims it — so starting a
                                    // marquee here would clear the selection and
                                    // rubber-band underneath the pan.
                                    if (pointerEvent.buttons &
                                            kMiddleMouseButton !=
                                        0) {
                                      return;
                                    }
                                    // Check if we're clicking on an asset first.
                                    // The hit-test respects the asset's rotation
                                    // via marqueeHitTestRotatedAsset — without it
                                    // the marquee gate would (a) start a marquee
                                    // when the operator clicks inside the rotated
                                    // visual but outside its pre-rotation AABB,
                                    // and (b) refuse to start a marquee when the
                                    // operator clicks empty visual space inside
                                    // the pre-rotation rect.
                                    bool hitAsset = assets.any((asset) {
                                      return editorHitTestAsset(
                                        pointer: pointerEvent.localPosition,
                                        asset: asset,
                                        assets: assets,
                                        canvas: Size(constraints.maxWidth,
                                            constraints.maxHeight),
                                      );
                                    });

                                    // A right-click is a menu, never a marquee: on
                                    // empty canvas it offers paste-at-cursor; on an
                                    // asset, AssetStack shows its own menu, so only
                                    // the marquee below has to stand down.
                                    if (pointerEvent.buttons ==
                                        kSecondaryMouseButton) {
                                      if (!hitAsset) {
                                        _showCanvasContextMenu(
                                          pointerEvent.position,
                                          Offset(
                                            (pointerEvent.localPosition.dx /
                                                    constraints.maxWidth)
                                                .clamp(0.0, 1.0),
                                            (pointerEvent.localPosition.dy /
                                                    constraints.maxHeight)
                                                .clamp(0.0, 1.0),
                                          ),
                                        );
                                      }
                                      return;
                                    }

                                    // Only start selection box if we didn't hit an asset
                                    if (!hitAsset) {
                                      // If no Ctrl/Cmd, clear any existing selection
                                      if (!_isModifierPressed(HardwareKeyboard
                                          .instance.logicalKeysPressed)) {
                                        setState(() {
                                          _selectedAssets.clear();
                                        });
                                      }
                                      // Record the start of the drag‐selection
                                      final box = context.findRenderObject()
                                          as RenderBox;
                                      final local = box
                                          .globalToLocal(pointerEvent.position);
                                      setState(() {
                                        _marqueeBaseSelection =
                                            Set.of(_selectedAssets);
                                        _selectionStart = local;
                                        _selectionCurrent = local;
                                      });
                                    }
                                  },
                                  onPointerMove: (pointerEvent) {
                                    // Only update selection if we have a valid selection start AND we're not dragging an asset
                                    if (_selectionStart != null &&
                                        !_isDraggingAsset) {
                                      final box = context.findRenderObject()
                                          as RenderBox;
                                      final local = box
                                          .globalToLocal(pointerEvent.position);
                                      setState(() {
                                        _selectionCurrent = local;

                                        final bounds = Rect.fromPoints(
                                            _selectionStart!,
                                            _selectionCurrent!);
                                        final boxed = assets.where((asset) {
                                          final cx = asset.coordinates.x *
                                              constraints.maxWidth;
                                          final cy = asset.coordinates.y *
                                              constraints.maxHeight;
                                          final halfW = (asset.size.width *
                                                  constraints.maxWidth) /
                                              2;
                                          final halfH = (asset.size.height *
                                                  constraints.maxHeight) /
                                              2;

                                          final assetRect = Rect.fromLTWH(
                                            cx -
                                                halfW, // Offset by half width to match Positioned widget
                                            cy -
                                                halfH, // Offset by half height to match Positioned widget
                                            asset.size.width *
                                                constraints.maxWidth,
                                            asset.size.height *
                                                constraints.maxHeight,
                                          );
                                          return bounds.overlaps(assetRect);
                                        }).toSet();
                                        _selectedAssets = {
                                          ..._marqueeBaseSelection
                                              .difference(boxed),
                                          ...boxed.difference(
                                              _marqueeBaseSelection),
                                        };
                                      });
                                    }
                                  },
                                  onPointerUp: (pointerEvent) {
                                    setState(() {
                                      _isDraggingAsset = false;
                                      _selectionStart = null;
                                      _selectionCurrent = null;
                                      _marqueeBaseSelection = {};
                                      // A drag deferred its JSON syncs (see
                                      // _moveAsset); this is where the gesture
                                      // settles, so run the one encode that
                                      // stands in for all of them.
                                      if (_currentJsonStale) {
                                        _updateCurrentJson();
                                      }
                                    });
                                  },
                                ),
                              if (_selectionStart != null &&
                                  _selectionCurrent != null)
                                CustomPaint(
                                  painter: SelectionBoxPainter(
                                    start: _selectionStart!,
                                    current: _selectionCurrent!,
                                  ),
                                ),
                              // A run is drawn, not placed, so the box-and-
                              // handles chrome has nothing useful to offer it.
                              // Topmost, so grabbing a handle is never read as
                              // the start of a marquee.
                              if (_selectedLink != null)
                                LinkEditOverlay(
                                  link: _selectedLink!,
                                  assets: assets,
                                  canvas: Size(constraints.maxWidth,
                                      constraints.maxHeight),
                                  onBeginEdit: _saveToHistory,
                                  onChanged: () =>
                                      setState(_updateCurrentJson),
                                ),
                              Positioned(
                                top: 16,
                                right: 16,
                                child: _buildPageSelector(),
                              ),
                              Positioned(
                                left: 16,
                                bottom: 16,
                                child: Row(
                                  children: [
                                    _buildHamburgerFab(assets),
                                    const SizedBox(width: 8),
                                    FloatingActionButton(
                                      mini: true,
                                      heroTag: 'save',
                                      backgroundColor: _hasUnsavedChanges
                                          ? Colors.orange
                                          : Theme.of(context)
                                              .colorScheme
                                              .primary,
                                      onPressed: _saveToPrefs,
                                      child: const Icon(Icons.save,
                                          color: Colors.white),
                                    ),
                                  ],
                                ),
                              ),
                              if (_showPalette)
                                Positioned.fill(
                                  child: GestureDetector(
                                    onTap: () =>
                                        setState(() => _showPalette = false),
                                    behavior: HitTestBehavior.translucent,
                                    child: Container(),
                                  ),
                                ),
                              if (_showPalette)
                                Positioned(
                                  top: 0,
                                  bottom: 0,
                                  left: 0,
                                  child: SizedBox(
                                    width: 320,
                                    child: Material(
                                      elevation: 8,
                                      color: Theme.of(context)
                                          .scaffoldBackgroundColor,
                                      borderRadius: BorderRadius.only(
                                        topRight: Radius.circular(12),
                                        bottomRight: Radius.circular(12),
                                      ),
                                      child: Stack(
                                        children: [
                                          _buildPalette(),
                                          Positioned(
                                            top: 8,
                                            right: 8,
                                            child: IconButton(
                                              icon: Icon(Icons.close),
                                              onPressed: () => setState(
                                                  () => _showPalette = false),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                right: 16,
                                bottom: 16,
                                // The mode toggle used to live at the bottom of this
                                // column. There is only one mode now, so what is left
                                // is the size pair, and it appears only when there is
                                // a selection to resize.
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_selectedAssets.isNotEmpty) ...[
                                      FloatingActionButton(
                                        mini: true,
                                        heroTag: 'increase',
                                        tooltip: 'Grow selection',
                                        onPressed: () =>
                                            _adjustSelectedAssetsSize(1.1),
                                        child: const Icon(Icons.add,
                                            color: Colors.white),
                                      ),
                                      const SizedBox(height: 8),
                                      FloatingActionButton(
                                        mini: true,
                                        heroTag: 'decrease',
                                        tooltip: 'Shrink selection',
                                        onPressed: () =>
                                            _adjustSelectedAssetsSize(0.9),
                                        child: const Icon(Icons.remove,
                                            color: Colors.white),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    )))),
          ],
        ),
      ),
    );
  }

  Widget _buildPalette() {
    final query = _paletteSearchController.text.trim().toLowerCase();
    var entries = AssetRegistry.defaultFactories.entries.toList();
    if (query.isNotEmpty) {
      final scored = <(int, MapEntry<Type, Asset Function()>)>[];
      for (final entry in entries) {
        final asset = entry.value();
        // Keywords let an umbrella asset be found by what it contains — the
        // 3rd-party tile answers to "multivac".
        final score = fuzzyScoreFields([
          asset.displayName.toLowerCase(),
          for (final k in asset.searchKeywords) k.toLowerCase(),
        ], query);
        if (score != null) scored.add((score, entry));
      }
      entries = rankedItems(scored);
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 48, 8),
          child: TextField(
            controller: _paletteSearchController,
            decoration: const InputDecoration(
              hintText: 'Search assets...',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(12.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.85,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final previewAsset = entry.value();
              Widget item = _PaletteItem(
                assetType: entry.key,
                asset: previewAsset,
              );
              if (kChatEnabled) {
                item = AiContextMenuWrapper(
                  menuItems: buildPaletteItemMenuItems(
                    asset: previewAsset,
                    pageName: _currentPage,
                    existingAssetSummary: summarizeExistingAssets(assets),
                  ),
                  child: item,
                );
              }
              return item;
            },
          ),
        ),
      ],
    );
  }

  /// The palette hamburger FAB, wrapped in the AI context menu only when the
  /// chat feature is compiled in ([kChatEnabled] is const, so the flag-off
  /// build tree-shakes the wrapper and its chat dependencies).
  Widget _buildHamburgerFab(List<Asset> assets) {
    Widget fab = FloatingActionButton(
      mini: true,
      heroTag: 'hamburger',
      backgroundColor: Theme.of(context).colorScheme.primary,
      onPressed: () => setState(() => _showPalette = true),
      child: const Icon(Icons.menu, color: Colors.white),
    );
    if (kChatEnabled) {
      fab = AiContextMenuWrapper(
        menuItems: buildHamburgerMenuItems(
          pageName: _currentPage ?? 'Untitled',
          assets: assets,
        ),
        child: fab,
      );
    }
    return fab;
  }

  /// Identifies one asset's pane. Assets have no stable id of their own, and
  /// two of the same type are equal only by identity, so that is what the id
  /// is built from — enough for `showSidePane` to tell "same asset, toggle
  /// shut" from "different asset, swap the contents".
  String _configPaneId(Asset asset) =>
      'page-editor-config:${identityHashCode(asset)}';

  /// The asset's on-screen rectangle, straight from its rendered element.
  ///
  /// Walks the canvas subtree for the [ObjectKey] that [AssetStack] hangs on
  /// each asset's `Positioned`, then reads the box's global rect — zoom,
  /// mirroring and rotation included, none of that geometry re-derived here.
  /// Null when the asset has no laid-out element yet (a paste opens its pane
  /// before the canvas has rebuilt); `showSidePane` then falls back to this
  /// page's own context and the canvas plays it safe by insetting.
  Rect? _assetScreenRect(Asset asset) {
    final canvas = _canvasContext;
    if (canvas == null || !canvas.mounted) return null;
    final key = ObjectKey(asset);
    RenderBox? box;
    void visit(Element element) {
      if (box != null) return;
      if (element.widget.key == key) {
        final ro = element.renderObject;
        if (ro is RenderBox && ro.hasSize) box = ro;
        return;
      }
      element.visitChildElements(visit);
    }

    canvas.visitChildElements(visit);
    final found = box;
    if (found == null) return null;
    return MatrixUtils.transformRect(
        found.getTransformTo(null), Offset.zero & found.size);
  }

  /// Docks [asset]'s configuration editor to the right of the canvas.
  ///
  /// This used to be a `showDialog`, which put a barrier over the canvas: the
  /// operator had to close it to see what a change did, and again to move the
  /// asset. The pane is non-modal, so the canvas underneath keeps taking
  /// drags, marquee selection and taps on other assets while it is open, and
  /// [_syncConfigEdits] mirrors edits onto the canvas as they are made.
  void _openConfigPane(Asset asset) {
    ref.read(currentPageAssetsProvider.notifier).state = assets;

    // Tapping the asset whose pane is already open closes it; `showSidePane`
    // has already run `_onConfigPaneClosed` for us by then.
    final opened = showSidePane(
      context: context,
      id: _configPaneId(asset),
      width: _configPaneWidth,
      resizable: true,
      onWidthChanged: (width) => setState(() => _configPaneWidth = width),
      builder: (paneContext) => _buildConfigPane(paneContext, asset),
      onClosed: _onConfigPaneClosed,
      // The canvas only steps aside when the pane would cover this very
      // asset; measured before the pane opens, so while the canvas is still
      // where the operator sees it.
      avoidRect: _assetScreenRect(asset),
    );
    if (!opened) return;

    setState(() {
      _configAsset = asset;
      _configSnapshot = _assetSnapshot(asset);
      // A fresh form: the first edit made in it opens an undo entry of its own
      // rather than folding into whatever the last one was for.
      _configEditKeys = null;
    });
    _configWatch?.cancel();
    _configWatch =
        Timer.periodic(_configWatchInterval, (_) => _syncConfigEdits());
  }

  /// Runs when the pane goes away for any reason — its Close button, Escape,
  /// a swap to another asset, or the editor being torn down.
  void _onConfigPaneClosed() {
    _configWatch?.cancel();
    _configWatch = null;
    if (!mounted) {
      _configAsset = null;
      _configSnapshot = null;
      _configEditKeys = null;
      return;
    }
    // A last pass, in case the closing interaction itself was the edit: the
    // watch ticks every 100 ms, and a change made on the way out would
    // otherwise reach the canvas without the undo entry it is owed.
    _syncConfigEdits();
    _configSnapshot = null;
    setState(() {
      _configAsset = null;
      _configEditKeys = null;
      // Belt and braces for an asset that would not serialize, which is the
      // one kind of edit the sync above cannot see.
      _updateCurrentJson();
    });
    // The pane may have held keyboard focus (its text fields live in the root
    // overlay); with it gone, the shortcuts take over again without the
    // operator having to click the canvas first.
    _shortcutFocus.requestFocus();
  }

  Widget _buildConfigPane(BuildContext paneContext, Asset asset) {
    final label = asset.text;
    return Listener(
      // Sync on the pointer event itself so slider drags and colour taps reach
      // the canvas in the same frame; the timer only has to cover edits that
      // arrive without one (typing, nested pickers, async key lookups).
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _syncConfigEdits(),
      onPointerMove: (_) => _syncConfigEdits(),
      onPointerUp: (_) => _syncConfigEdits(),
      child: SidePane(
        title: asset.displayName,
        subtitle: label != null && label.isNotEmpty ? label : null,
        icon: Icons.tune,
        // Every config editor brings its own scrolling and sizing; wrapping
        // them in another scroll view would leave the ones that use `Expanded`
        // with an unbounded height.
        scrollable: false,
        actions: [
          PaneAction.destructive(
            label: 'Delete',
            icon: Icons.delete,
            onPressed: () => _deleteConfiguredAsset(asset),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Column(
            children: [
              Expanded(child: asset.configure(paneContext)),
              if (kKnowledgeEnabled && asset is BaseAsset)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: TechDocPicker(
                    selectedDocId: asset.techDocId,
                    onChanged: (id) {
                      asset.techDocId = id;
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The one properties pane. Unlike the per-asset config pane there is never
  /// more than one, and it survives the selection changing under it, so its
  /// id is fixed rather than derived from what it is showing.
  static const String _bulkPaneId = 'page-editor:properties';

  /// Docks the multi-select property editor to the right of the canvas.
  ///
  /// This is what the context menu's Edit does for a selection of more than
  /// one asset: [configure] can only edit the asset it was handed, so
  /// widening four drives at once needs the narrower, shared description of
  /// an asset that [Asset.bulkProperties] gives.
  void _openBulkEditPane(List<Asset> targets) {
    if (targets.isEmpty) return;
    ref.read(currentPageAssetsProvider.notifier).state = assets;

    // Already up: re-point it rather than let `showSidePane`'s toggle read as
    // the pane refusing to open, the same guard the Edit entry uses for the
    // single-asset pane.
    if (_bulkPaneSelection != null) {
      setState(() => _bulkPaneSelection = List.of(targets));
      _bulkRevision.value++;
      return;
    }

    // The per-asset pane closes: only one side pane fits, and the two would
    // otherwise fight over the strip.
    _closeConfigPane();

    final opened = showSidePane(
      context: context,
      id: _bulkPaneId,
      width: _bulkPaneWidth,
      resizable: true,
      onWidthChanged: (width) => setState(() => _bulkPaneWidth = width),
      builder: _buildBulkPane,
      onClosed: _onBulkPaneClosed,
      avoidRect: _selectionScreenRect(targets),
    );
    if (!opened) return;
    setState(() => _bulkPaneSelection = List.of(targets));
  }

  void _onBulkPaneClosed() {
    if (!mounted) {
      _bulkPaneSelection = null;
      return;
    }
    setState(() => _bulkPaneSelection = null);
    // The pane's text fields live in the root overlay and hold keyboard
    // focus; with it gone the canvas shortcuts take over again without the
    // operator having to click the canvas first. Same as [_onConfigPaneClosed].
    _shortcutFocus.requestFocus();
  }

  /// The bounding box of [targets] on screen, so the canvas only steps aside
  /// when the pane would actually cover what is being edited. Assets with no
  /// laid-out element yet are skipped; null (nothing measurable) makes
  /// `showSidePane` play it safe and inset.
  Rect? _selectionScreenRect(List<Asset> targets) {
    Rect? union;
    for (final asset in targets) {
      final rect = _assetScreenRect(asset);
      if (rect == null) continue;
      union = union == null ? rect : union.expandToInclude(rect);
    }
    return union;
  }

  Widget _buildBulkPane(BuildContext paneContext) {
    return ListenableBuilder(
      listenable: _bulkRevision,
      builder: (context, _) {
        final selection = _bulkPaneSelection ?? const <Asset>[];
        return SidePane(
          title: selection.length == 1
              ? selection.single.displayName
              : '${selection.length} assets',
          subtitle: _bulkPaneSubtitle(selection),
          icon: Icons.tune,
          // The editor brings its own scrolling; see [_buildConfigPane].
          scrollable: false,
          child: BulkPropertyEditor(
            selection: selection,
            revision: _bulkRevision,
            onBeforeChange: _saveToHistory,
            onChanged: () => _updateState(() {}),
          ),
        );
      },
    );
  }

  /// What is selected, by kind: 'Schneider ATV320 x4', or the mix when the
  /// selection is not all one thing. Named kinds rather than a bare count
  /// because the rows on offer depend on them — a selection that has lost its
  /// device-specific section has usually picked up one asset of another kind.
  static String? _bulkPaneSubtitle(List<Asset> selection) {
    if (selection.length < 2) return null;
    final counts = <String, int>{};
    for (final asset in selection) {
      counts.update(asset.displayName, (n) => n + 1, ifAbsent: () => 1);
    }
    final parts = [
      for (final entry in counts.entries)
        entry.value > 1 ? '${entry.key} \u00d7${entry.value}' : entry.key,
    ];
    // Three kinds is already a longer subtitle than the header has room for.
    if (parts.length > 3) return '${counts.length} kinds of asset';
    return parts.join(', ');
  }

  /// Keeps the open properties pane pointed at the live selection.
  ///
  /// The pane is an overlay entry built once, so a marquee that grows the
  /// selection, a Ctrl-click that shrinks it, or a delete that empties it
  /// would otherwise leave it editing assets that are no longer selected —
  /// or no longer on the page. Called from [build], where every one of those
  /// has already landed in [_selectedAssets]; the work itself is deferred to
  /// after the frame because it notifies a listener.
  void _refreshBulkPane() {
    if (_bulkPaneSelection == null) return;
    // A rubber-band drag clears the selection on the way down and rebuilds it
    // as the box grows, so mid-drag it passes through empty and through every
    // partial set. Following that would flicker the pane's rows and — since
    // an empty selection closes it — shut it halfway through the gesture.
    // The drag settles into one more build when the pointer lifts.
    if (_selectionStart != null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _bulkPaneSelection == null) return;
      // Recomputed here rather than captured above: several frames can each
      // queue a callback, and one holding the selection as it stood two
      // frames ago would undo the newest rebind — or close a pane over a
      // selection that has since come back.
      final live = _liveSelection();
      // Nothing left to edit — an operator who deleted the selection is done
      // with the pane, and an empty one is just a dead strip.
      if (live.isEmpty) {
        closeSidePane(id: _bulkPaneId);
        return;
      }
      if (_sameAssets(live, _bulkPaneSelection!)) return;
      setState(() => _bulkPaneSelection = live);
      _bulkRevision.value++;
    });
  }

  /// The selection in page order, which is the order the pane lists it in.
  List<Asset> _liveSelection() => [
        for (final asset in assets)
          if (_selectedAssets.contains(asset)) asset,
      ];

  /// Whether two selections hold the same assets in the same order.
  ///
  /// By identity: a rebuilt asset (undo, paste) is a different object holding
  /// the same values, and the pane's rows must be rebound onto it or they
  /// write to an instance no longer on the page.
  static bool _sameAssets(List<Asset> a, List<Asset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// Repaints the canvas when the open pane has changed its asset.
  ///
  /// Config editors write straight into the asset they were handed and call
  /// `setState` on themselves, so there is no callback to hook. Comparing the
  /// asset's own serialization catches every one of them without touching the
  /// ~45 editors, and costs one small `jsonEncode` per check.
  void _syncConfigEdits() {
    final asset = _configAsset;
    if (asset == null) return;

    // The asset can leave the canvas while its pane is up: deleted with the
    // keyboard, undone, or left behind by a page change.
    if (!assets.contains(asset)) {
      closeSidePane(id: _configPaneId(asset));
      return;
    }

    final previous = _configSnapshot;
    final snapshot = _assetSnapshot(asset);
    if (snapshot == null || snapshot == previous) return;

    // The pane writes straight into its asset, so this is the only place an
    // undo entry can be opened for what it does — and it has to happen before
    // the encode below, while [_currentJson] still holds the page as it was
    // before this change. Without it Ctrl+Z skipped every pane edit and undid
    // whatever came before them instead, silently keeping the edit.
    //
    // Mid-gesture on the canvas ([_currentJsonStale]) there is nothing to open:
    // that gesture pushed its own entry at the start and its coordinates are
    // what would be saved here.
    if (previous != null && !_currentJsonStale) {
      final changed = changedTopLevelKeys(previous, snapshot);
      final open = _configEditKeys;
      if (changed == null || open == null || !changed.every(open.contains)) {
        _saveToHistory(); // Clears _configEditKeys.
        _configEditKeys = changed ?? const {};
      }
    }

    setState(() {
      _configSnapshot = snapshot;
      _updateCurrentJson();
    });
  }

  /// [asset] as JSON, or null if it will not serialize — in which case the
  /// pane simply falls back to updating the canvas when it closes.
  String? _assetSnapshot(Asset asset) {
    try {
      return jsonEncode(asset.toJson());
    } catch (_) {
      return null;
    }
  }

  void _deleteConfiguredAsset(Asset asset) {
    closeSidePane(id: _configPaneId(asset));
    _saveToHistory();
    _updateState(() {
      assets.remove(asset);
      _selectedAssets.remove(asset);
    });
  }

  void _moveAsset(
      Asset asset, DragUpdateDetails details, BoxConstraints constraints) {
    // If the dragged asset is selected, move all selected assets
    final assetsToMove =
        _selectedAssets.contains(asset) ? _selectedAssets.toList() : [asset];

    // `details.delta` arrives in the local coord space of the GestureDetector
    // that received the event. The selection-rotation fix wrapped that
    // GestureDetector inside `Transform.rotate(angle)`, so for a rotated
    // asset the local frame is rotated and a screen-right drag arrives as
    // local-down (and vice versa). projectDragDeltaToCanvas projects the
    // delta back into the canvas (parent) frame. For angle == 0 it's an
    // identity transform — behaviour matches the pre-rotation editor exactly.
    final canvasDelta = projectDragDeltaToCanvas(
      delta: details.delta,
      angleDegrees: asset.coordinates.angle ?? 0.0,
    );

    // A drag delivers an update per pointer event; the JSON sync waits for
    // the pointer up in the canvas Listener.
    _updateState(deferJsonSync: true, () {
      for (final assetToMove in assetsToMove) {
        final newX =
            (assetToMove.coordinates.x + canvasDelta.dx / constraints.maxWidth)
                .clamp(0.0, 1.0);
        final newY =
            (assetToMove.coordinates.y + canvasDelta.dy / constraints.maxHeight)
                .clamp(0.0, 1.0);

        assetToMove.coordinates =
            Coordinates(x: newX, y: newY, angle: assetToMove.coordinates.angle);
      }
    });
  }

  void _adjustSelectedAssetsSize(double factor) {
    _saveToHistory();
    setState(() {
      for (final asset in _selectedAssets) {
        asset.size = RelativeSize(
          width: (asset.size.width * factor).clamp(0.01, 1.0),
          height: (asset.size.height * factor).clamp(0.01, 1.0),
        );
      }
      _updateCurrentJson();
    });
  }

  Widget _buildPageSelector() {
    final currentPagePath = _currentPage ?? _temporaryPages.keys.firstOrNull;
    final displayName = currentPagePath != null
        ? (_temporaryPages[currentPagePath]?.menuItem.label ?? 'Empty')
        : 'Empty';
    final currentPage =
        currentPagePath != null ? _temporaryPages[currentPagePath] : null;

    final selector = GestureDetector(
      onTap: _showPageManagerDialog,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(displayName),
            // Which page you are on is obvious; that operators cannot see it
            // is not, and it is the kind of thing that gets left switched off
            // once the page is finished.
            if (currentPage != null && !currentPage.published) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Draft — not published to the navigation menu',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_off,
                        size: 16, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 4),
                    Text(
                      'Draft',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(width: 8),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );

    // Wrap with right-click context menu that includes both direct actions
    // (Create New Page) and AI chat actions when page data is available.
    if (currentPagePath != null && currentPage != null) {
      return GestureDetector(
        onSecondaryTapUp: (details) {
          if (kChatEnabled) {
            _showPageSelectorContextMenu(
              details.globalPosition,
              currentPagePath,
              currentPage,
            );
          } else {
            // Without chat the only page-selector action is Create New Page.
            _showCreateNewPageContextMenu(details.globalPosition);
          }
        },
        child: selector,
      );
    }

    // No page selected -- still allow right-click to create a new page.
    return GestureDetector(
      onSecondaryTapUp: (details) {
        _showCreateNewPageContextMenu(details.globalPosition);
      },
      child: selector,
    );
  }

  /// Shows a context menu for the page selector with "Create New Page" and
  /// AI actions. Intercepts the [kCreateNewPageAction] sentinel to open the
  /// page manager dialog instead of chat.
  Future<void> _showPageSelectorContextMenu(
    Offset position,
    String pagePath,
    AssetPage page,
  ) async {
    final menuItems = buildPageSelectorMenuItems(pagePath, page);

    final result = await showMenu<int>(
      context: context,
      useRootNavigator: true,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        for (var i = 0; i < menuItems.length; i++) ...[
          // Add a divider after "Create New Page" to separate direct actions
          // from AI actions.
          if (i == 1) const PopupMenuDivider(),
          PopupMenuItem<int>(
            value: i,
            child: ListTile(
              leading: Icon(menuItems[i].icon),
              title: Text(menuItems[i].label),
              dense: true,
            ),
          ),
        ],
      ],
    );

    if (result == null || !mounted) return;

    final item = menuItems[result];

    // Intercept "Create New Page" -- open the page manager dialog directly.
    if (item.prefillText == kCreateNewPageAction) {
      _showPageManagerDialog();
      return;
    }

    // Otherwise delegate to AI chat action.
    if (item.sendImmediately) {
      AiContextAction.openChatAndSend(ref: ref, message: item.prefillText);
    } else {
      ChatContext? chatContext;
      if (item.contextBlock != null) {
        chatContext = ChatContext(
          label: item.contextLabel ?? item.label,
          type: item.contextType,
          contextBlock: item.contextBlock!,
        );
      }
      AiContextAction.openChat(
        ref: ref,
        prefillText: item.prefillText,
        context: chatContext,
      );
    }
  }

  /// Shows a minimal context menu with just "Create New Page" when no page
  /// is currently selected.
  Future<void> _showCreateNewPageContextMenu(Offset position) async {
    final result = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      clipBehavior: Clip.antiAlias,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'create',
          child: ListTile(
            leading: Icon(Icons.add_circle_outline),
            title: Text('Create New Page'),
            dense: true,
          ),
        ),
      ],
    );

    if (result == 'create' && mounted) {
      _showPageManagerDialog();
    }
  }

  /// Returns page paths that are not referenced as children of any OTHER page.
  List<String> _getRootPageNames() {
    final childPaths = <String>{};
    for (final entry in _temporaryPages.entries) {
      PageManager.collectChildPaths(
          entry.value.menuItem.children, childPaths, entry.key);
    }
    final roots = _temporaryPages.keys
        .where((path) => !childPaths.contains(path))
        .toList();

    // A page can be somebody's child and still hang off nothing — two
    // sections naming each other, or a subtree whose only parent was edited
    // out of the stored JSON by hand. Those pages are in the file and in the
    // save, but walking down from the roots never reaches them, so the Pages
    // dialog showed no trace of them at all: not to open, not to move, not to
    // delete. Treating them as roots is what puts them back within reach.
    final reachable = <String>{};
    final queue = List<String>.from(roots);
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      if (!reachable.add(current)) continue;
      for (final child in _temporaryPages[current]?.menuItem.children ??
          const <MenuItem>[]) {
        final path = child.path;
        if (path == null || path.isEmpty || path == current) continue;
        if (_temporaryPages.containsKey(path)) queue.add(path);
      }
    }
    roots.addAll(
        _temporaryPages.keys.where((path) => !reachable.contains(path)));

    roots.sort((a, b) {
      final pa = _temporaryPages[a]?.navigationPriority ?? 999;
      final pb = _temporaryPages[b]?.navigationPriority ?? 999;
      return pa.compareTo(pb);
    });
    return roots;
  }

  /// Top-level items the app registered itself (Alarm View, Advanced, ...),
  /// keyed by path. They are not pages, so the dialog can only reorder them.
  /// Built-in destinations whose menu placement the operator may change
  /// between the top level and the Advanced section. Placement is recorded
  /// as membership in the shared top-level order — no second key to drift.
  static const Set<String> movableBuiltinPaths = {AppRoutes.historyView};

  /// Whether the operator's (unsaved) arrangement has [path] at the top
  /// level rather than under Advanced.
  bool _isBuiltinPromoted(String path) => _topLevelOrder.contains(path);

  /// Finds [path]'s menu item anywhere in the registry tree — movable
  /// built-ins live under Advanced by default, so a top-level scan misses
  /// them.
  MenuItem? _findRegistryItem(String path, [List<MenuItem>? items]) {
    for (final item in items ?? RouteRegistry().menuItems) {
      if (item.path == path) return item;
      final nested = _findRegistryItem(path, item.children);
      if (nested != null) return nested;
    }
    return null;
  }

  Map<String, MenuItem> _appRegisteredTopLevel() {
    final map = {
      for (final item in RouteRegistry().menuItems)
        if (item.path != null && !_temporaryPages.containsKey(item.path))
          item.path!: item,
    };
    // Movable built-ins follow the editor's (possibly unsaved) placement,
    // not the registry's — the registry only changes on restart.
    for (final path in movableBuiltinPaths) {
      final item = _findRegistryItem(path);
      if (item == null) continue; // app without this destination
      if (_isBuiltinPromoted(path)) {
        map.putIfAbsent(path, () => item);
      } else {
        map.remove(path);
      }
    }
    return map;
  }

  /// Movable built-ins currently placed under Advanced — offered a
  /// "move to top level" affordance below the list.
  List<MenuItem> _demotedMovableBuiltins() => [
        for (final path in movableBuiltinPaths)
          if (!_isBuiltinPromoted(path))
            if (_findRegistryItem(path) case final MenuItem item) item,
      ];

  /// Moves [path] to the top level: freezes the currently displayed
  /// arrangement into the order list and appends [path], so the promotion
  /// survives restarts (placement IS membership in the stored order).
  void _promoteBuiltin(String path, StateSetter dialogSetState) {
    _saveToHistory();
    setState(() {
      _topLevelOrder = [
        ..._getTopLevelPaths().where((p) => p != path),
        path,
      ];
      _navOrderDirty = true;
    });
    dialogSetState(() {});
  }

  /// Moves [path] back under Advanced by dropping it from the stored order.
  void _demoteBuiltin(String path, StateSetter dialogSetState) {
    _saveToHistory();
    setState(() {
      _topLevelOrder = [..._topLevelOrder.where((p) => p != path)];
      _navOrderDirty = true;
    });
    dialogSetState(() {});
  }

  /// Every top-level row of the Pages dialog — root pages and the app's own
  /// destinations — in navigation order.
  ///
  /// Rows the stored order does not know yet rank by the live registry order
  /// (what the running app currently shows); pages absent from both — drafts
  /// and pages created this session, which enter the registry only on restart
  /// — go last, in priority order.
  List<String> _getTopLevelPaths() {
    final pageRoots = _getRootPageNames();
    final externals = _appRegisteredTopLevel().keys.toList();

    final registryPaths = [
      for (final item in RouteRegistry().menuItems)
        if (item.path != null) item.path!,
    ];
    final rank = <String, int>{};
    for (final path in _topLevelOrder) {
      rank.putIfAbsent(path, () => rank.length);
    }
    var next = rank.length;
    for (final path in registryPaths) {
      rank.putIfAbsent(path, () => next++);
    }
    for (final path in pageRoots) {
      rank.putIfAbsent(path, () => next++);
    }

    final combined = [...pageRoots, ...externals];
    combined.sort((a, b) => rank[a]!.compareTo(rank[b]!));
    return combined;
  }

  Future<void> _showPageManagerDialog() async {
    // Fetch this station's startup URL before the dialog builds, so the
    // rocket lights up on the right row from the first frame.
    _startupUrl = await readStartupUrl(ref.read(localPreferencesProvider));
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, dialogSetState) {
          final roots = _getTopLevelPaths();
          final appItems = _appRegisteredTopLevel();
          // One set for the whole tree, so a page listed under two sections
          // (or a pair of sections naming each other) is drawn once and the
          // recursion cannot chase itself off the stack.
          final visited = <String>{};
          return StandardDialogFrame(
            title: 'Pages',
            // The restart caveat belongs with the change, not buried in the
            // button row it used to share with Close.
            subtitle: 'Navigation changes require an app restart',
            icon: Icons.menu_book,
            width: 590,
            child: SizedBox(
              width: 550,
              // StandardDialogFrame caps itself at 80% of the screen, so a
              // taller fixed box pushes the drop zone and the add buttons off
              // a short panel where they cannot be reached at all. Shrink to
              // whatever the frame can actually give, minus its own header.
              height:
                  math.min(550, MediaQuery.sizeOf(context).height * 0.8 - 120),
              child: Column(
                children: [
                  Text(
                    'Tap to select. Sections are navigation groups. Drag the '
                    'handle to reorder within a level; hold and drag a row '
                    'onto a section — or onto "Top level" — to move it there.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ReorderableListView(
                      key: _treeViewportKey,
                      scrollController: _treeScrollController,
                      buildDefaultDragHandles: false,
                      onReorder: (oldIndex, newIndex) {
                        _onReorderRoots(
                            roots, oldIndex, newIndex, dialogSetState);
                      },
                      children: [
                        for (int i = 0; i < roots.length; i++)
                          if (appItems.containsKey(roots[i]))
                            _buildAppItemNode(
                              appItems[roots[i]]!,
                              reorderIndex: i,
                              dialogSetState: dialogSetState,
                              dialogContext: context,
                            )
                          else
                            _buildTreeNode(
                              roots[i],
                              dialogSetState,
                              dialogContext,
                              depth: 0,
                              reorderIndex: i,
                              visited: visited,
                            ),
                      ],
                    ),
                  ),
                  _buildTopLevelDropZone(dialogSetState),
                  for (final item in _demotedMovableBuiltins())
                    ListTile(
                      key: ValueKey('advanced-builtin-${item.path}'),
                      dense: true,
                      leading: Icon(item.icon),
                      title: Text(item.label),
                      subtitle: const Text('Built-in — in Advanced'),
                      trailing: TextButton.icon(
                        key: ValueKey('promote-builtin-${item.path}'),
                        icon: const Icon(Icons.vertical_align_top, size: 18),
                        label: const Text('Move to top level'),
                        onPressed: () =>
                            _promoteBuiltin(item.path!, dialogSetState),
                      ),
                    ),
                  const Divider(),
                  _buildAddButtons(null, dialogSetState, dialogContext),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// The row's second line: what the entry is, and whether operators can see
  /// it. Null when there is nothing to say (a plain, published page).
  Widget? _treeNodeSubtitle({
    required bool isSection,
    required bool isDraft,
    bool isStartup = false,
  }) {
    final parts = [
      if (isSection) 'Section',
      if (isDraft) 'Draft — not published',
      if (isStartup) 'Startup page — this station',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '));
  }

  /// Makes [path] this station's startup URL — or, when it already is,
  /// resets to the default. Takes effect on the next app start, like every
  /// other change made in this dialog.
  void _setStartupUrl(String path, StateSetter dialogSetState) {
    final previous = _startupUrl;
    _startupUrl = _startupUrl == path ? startupUrlDefault : path;
    _writeStartupUrl(revertTo: previous);
    dialogSetState(() {});
  }

  /// Points this station's startup setting at [path] without asking, because
  /// the page it named has just been renamed or deleted out from under it.
  void _retargetStartupUrl(String path) {
    final previous = _startupUrl;
    _startupUrl = path;
    _writeStartupUrl(revertTo: previous);
  }

  /// Persists [_startupUrl]. The write is not awaited — the rocket has to
  /// light the moment it is tapped — but a failure is no longer swallowed:
  /// the field goes back to [revertTo] so the icon stops claiming something
  /// that never reached the disk, and the operator is told.
  void _writeStartupUrl({required String revertTo}) {
    unawaited(
      writeStartupUrl(ref.read(localPreferencesProvider), _startupUrl)
          .catchError((Object e) {
        debugPrint('startup URL write failed: $e');
        if (!mounted) return;
        setState(() => _startupUrl = revertTo);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save the startup page on this station: '
                '$e'),
          ),
        );
      }),
    );
  }

  /// The per-row toggle marking [path] as this station's startup page.
  Widget _startupToggle(
      String path, StateSetter dialogSetState, BuildContext dialogContext) {
    final isStartup = _startupUrl == path;
    return IconButton(
      key: ValueKey('startup-$path'),
      icon: Icon(
        isStartup ? Icons.rocket_launch : Icons.rocket_launch_outlined,
        size: 18,
        color: isStartup ? Theme.of(dialogContext).colorScheme.primary : null,
      ),
      onPressed: () => _setStartupUrl(path, dialogSetState),
      tooltip: isStartup
          ? 'This station starts here — tap to reset to the default (/)'
          : 'Start this station on this page',
    );
  }

  /// Publishes or unpublishes [pagePath].
  ///
  /// Nothing about the page itself changes — it keeps its path, its assets and
  /// its place in the tree, and stays editable here. Only whether
  /// `getRootMenuItems` hands it to the app's menu and router does, which the
  /// running app picks up on its next start (as the dialog's subtitle warns).
  /// Publishes [pagePath] for [group], or for everyone when null.
  ///
  /// Same shape as [_setPagePublished]: history first, then the page map, and
  /// the running app picks it up on its next start via
  /// `declareMenuRouteGroups`. Clearing goes through `clearRequiredGroup`
  /// because `copyWith(requiredGroup: null)` means "leave it alone".
  void _setPageRequiredGroup(
    String pagePath,
    AccessGroup? group,
    StateSetter dialogSetState,
  ) {
    final page = _temporaryPages[pagePath];
    if (page == null || page.menuItem.requiredGroup == group) return;
    _saveToHistory();
    setState(() {
      _temporaryPages[pagePath] = page.copyWith(
        menuItem: group == null
            ? page.menuItem.copyWith(clearRequiredGroup: true)
            : page.menuItem.copyWith(requiredGroup: group),
      );
      _updateCurrentJson();
    });
    dialogSetState(() {});
  }

  void _setPagePublished(
    String pagePath,
    bool published,
    StateSetter dialogSetState,
  ) {
    final page = _temporaryPages[pagePath];
    if (page == null || page.published == published) return;
    _saveToHistory();
    setState(() {
      _temporaryPages[pagePath] = page.copyWith(published: published);
      _updateCurrentJson();
    });
    dialogSetState(() {});
  }

  Widget _buildTreeNode(
    String pageName,
    StateSetter dialogSetState,
    BuildContext dialogContext, {
    required int depth,
    required int reorderIndex,
    required Set<String> visited,
  }) {
    final page = _temporaryPages[pageName];
    if (page == null) return SizedBox(key: ValueKey(pageName));
    visited.add(pageName);

    final isSelected = _currentPage == pageName;
    final displayName = page.menuItem.label;
    final hasChildren = page.menuItem.children.isNotEmpty;
    // An empty section is still a section — otherwise a freshly created one
    // would render as a page and could never receive children.
    final isSection = page.menuItem.isNavigationSection;
    final isDraft = !page.published;

    Widget row = ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: reorderIndex,
            child: const Icon(Icons.drag_handle, size: 20, color: Colors.grey),
          ),
          const SizedBox(width: 4),
          Icon(
            page.menuItem.icon,
            color: isSelected && !isSection
                ? Theme.of(dialogContext).colorScheme.primary
                : null,
          ),
        ],
      ),
      title: Text(
        displayName,
        style: TextStyle(
          fontWeight:
              isSelected && !isSection ? FontWeight.bold : FontWeight.normal,
          color: isSelected && !isSection
              ? Theme.of(dialogContext).colorScheme.primary
              : null,
        ),
      ),
      subtitle: _treeNodeSubtitle(
        isSection: isSection,
        isDraft: isDraft,
        // The default gets no subtitle: with nothing chosen the lit rocket
        // on `/` says enough, and the common case stays one line tall.
        isStartup: !isSection &&
            _startupUrl == pageName &&
            _startupUrl != startupUrlDefault,
      ),
      selected: isSelected && !isSection,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isSection)
            _startupToggle(pageName, dialogSetState, dialogContext),
          if (isSection && depth < 3)
            PopupMenuButton<String>(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add child',
              onSelected: (value) {
                _addItem(
                  parentName: pageName,
                  isSection: value == 'section',
                  dialogSetState: dialogSetState,
                  dialogContext: dialogContext,
                );
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'page',
                  child: Text('Add Page'),
                ),
                const PopupMenuItem(
                  value: 'section',
                  child: Text('Add Section'),
                ),
              ],
            )
          else if (isSection)
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Add page',
              onPressed: () => _addItem(
                parentName: pageName,
                isSection: false,
                dialogSetState: dialogSetState,
                dialogContext: dialogContext,
              ),
            ),
          // Published for a group, or for everyone. A popup rather than a
          // dialog: one tap to see the choice, one to make it. Entries carry
          // their own onTap because PopupMenuButton.onSelected never fires for
          // a null value, and null -- Everyone -- is a choice here.
          Builder(builder: (context) {
            final group = _temporaryPages[pageName]?.menuItem.requiredGroup;
            return PopupMenuButton<AccessGroup?>(
              tooltip: group == null
                  ? 'Published for everyone'
                  : 'Published for ${group.label}',
              icon: Icon(
                group == null ? Icons.lock_open : Icons.lock_outline,
                size: 18,
                color: group == null
                    ? null
                    : Theme.of(dialogContext).colorScheme.primary,
              ),
              itemBuilder: (context) => [
                PopupMenuItem<AccessGroup?>(
                  onTap: () =>
                      _setPageRequiredGroup(pageName, null, dialogSetState),
                  child: const Text('Everyone'),
                ),
                for (final g in AccessGroup.values)
                  PopupMenuItem<AccessGroup?>(
                    onTap: () =>
                        _setPageRequiredGroup(pageName, g, dialogSetState),
                    child: Text(g.label),
                  ),
              ],
            );
          }),
          IconButton(
            icon: Icon(
              isDraft ? Icons.visibility_off : Icons.visibility,
              size: 18,
              color: isDraft ? Theme.of(dialogContext).colorScheme.error : null,
            ),
            onPressed: () =>
                _setPagePublished(pageName, isDraft, dialogSetState),
            tooltip: isDraft
                ? (isSection
                    ? 'Publish section'
                    : 'Publish — operators can reach it')
                : (isSection
                    ? 'Unpublish section and everything in it'
                    : 'Unpublish — keep editing, hide from operators'),
          ),
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline, size: 18),
            onPressed: () =>
                _showMoveDialog(pageName, dialogSetState, dialogContext),
            tooltip: isSection ? 'Move section' : 'Move to section',
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () =>
                _editPage(pageName, page, dialogSetState, dialogContext),
            tooltip: 'Edit',
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18),
            onPressed: () =>
                _deletePage(pageName, dialogSetState, dialogContext),
            tooltip: 'Delete',
          ),
        ],
      ),
      onTap: isSection
          ? null
          : () {
              setState(() => _currentPage = pageName);
              Navigator.pop(dialogContext);
              // Opening a page is what stages the proposals left pending for
              // it when the editor was launched on another page.
              _stagePendingForCurrentPage();
            },
    );

    if (kChatEnabled) {
      row = AiContextMenuWrapper(
        menuItems: [
          AiMenuItem(
            label: 'Describe this page',
            prefillText:
                'Describe page "$displayName" (key: $pageName) — what assets does it contain and what is it monitoring?',
          ),
          AiMenuItem(
            label: 'Improve layout',
            prefillText:
                'Review page "$displayName" (key: $pageName) and suggest layout improvements or missing assets.',
          ),
          AiMenuItem(
            label: 'Duplicate with AI',
            prefillText:
                'Create a new page similar to "$displayName" (key: $pageName) but for [describe the target system].',
          ),
        ],
        child: row,
      );
    }

    return Padding(
      key: ValueKey(pageName),
      padding: EdgeInsets.only(left: depth > 0 ? 20.0 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _draggableRow(
            pageName: pageName,
            page: page,
            depth: depth,
            isSection: isSection,
            row: row,
            dialogSetState: dialogSetState,
          ),
          // Render children recursively with reordering
          if (hasChildren)
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorder: (oldIndex, newIndex) {
                _onReorderChildren(
                    pageName, oldIndex, newIndex, dialogSetState);
              },
              children: [
                for (int i = 0; i < page.menuItem.children.length; i++)
                  _buildChildNode(
                    page.menuItem.children[i],
                    pageName,
                    dialogSetState,
                    dialogContext,
                    depth: depth + 1,
                    reorderIndex: i,
                    visited: visited,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Picks the row for one entry in a section's children list.
  ///
  /// The list is stored data, so it can hold entries the tree cannot follow:
  /// an item with no address, one naming a page that is gone, or — where two
  /// sections name each other — one that has already been drawn further up.
  /// Each used to collapse into a keyless placeholder, and two of them in the
  /// same list took the whole editor down with a duplicate-key assertion.
  /// They get a visible, individually-keyed row instead, so the entry can be
  /// seen and deleted rather than crashing the dialog it lives in.
  Widget _buildChildNode(
    MenuItem child,
    String parentPath,
    StateSetter dialogSetState,
    BuildContext dialogContext, {
    required int depth,
    required int reorderIndex,
    required Set<String> visited,
  }) {
    final path = child.path;

    // A section listing itself is its own landing page, not a step down.
    if (path == parentPath) {
      return _buildSelfRefChild(
        child,
        parentPath,
        dialogSetState,
        dialogContext,
        depth: depth,
        reorderIndex: reorderIndex,
      );
    }

    if (path == null || path.isEmpty) {
      return _buildBrokenChildRow(
        key: ValueKey('broken-$parentPath-$reorderIndex'),
        label: child.label,
        icon: child.icon,
        reason: 'No address — this entry points nowhere',
        parentPath: parentPath,
        childItem: child,
        dialogSetState: dialogSetState,
        dialogContext: dialogContext,
        reorderIndex: reorderIndex,
      );
    }

    if (!_temporaryPages.containsKey(path)) {
      return _buildBrokenChildRow(
        key: ValueKey('broken-$parentPath-$reorderIndex'),
        label: child.label,
        icon: child.icon,
        reason: 'Missing page — nothing lives at $path',
        parentPath: parentPath,
        childItem: child,
        dialogSetState: dialogSetState,
        dialogContext: dialogContext,
        reorderIndex: reorderIndex,
      );
    }

    if (visited.contains(path)) {
      return _buildBrokenChildRow(
        key: ValueKey('repeat-$parentPath-$reorderIndex'),
        label: child.label,
        icon: child.icon,
        reason: 'Listed twice — shown higher up the tree',
        parentPath: parentPath,
        childItem: child,
        dialogSetState: dialogSetState,
        dialogContext: dialogContext,
        reorderIndex: reorderIndex,
      );
    }

    return _buildTreeNode(
      path,
      dialogSetState,
      dialogContext,
      depth: depth,
      reorderIndex: reorderIndex,
      visited: visited,
    );
  }

  /// A children-list entry the tree cannot follow, shown so it can be removed.
  Widget _buildBrokenChildRow({
    required Key key,
    required String label,
    required IconData icon,
    required String reason,
    required String parentPath,
    required MenuItem childItem,
    required StateSetter dialogSetState,
    required BuildContext dialogContext,
    required int reorderIndex,
  }) {
    final scheme = Theme.of(dialogContext).colorScheme;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(left: 20.0),
      child: ListTile(
        dense: true,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReorderableDragStartListener(
              index: reorderIndex,
              child:
                  const Icon(Icons.drag_handle, size: 20, color: Colors.grey),
            ),
            const SizedBox(width: 4),
            Icon(icon, color: scheme.error),
          ],
        ),
        title: Text(label.isEmpty ? '(unnamed)' : label),
        subtitle: Text(reason, style: TextStyle(color: scheme.error)),
        trailing: IconButton(
          icon: const Icon(Icons.delete, size: 18),
          tooltip: 'Remove this entry',
          onPressed: () => _removeBrokenChild(
            parentPath,
            reorderIndex,
            childItem,
            dialogSetState,
          ),
        ),
      ),
    );
  }

  /// Drops the [index]th entry of [parentPath]'s children list. Indexed
  /// rather than matched by path, because the entries this clears up are
  /// exactly the ones whose path is missing or duplicated.
  void _removeBrokenChild(
    String parentPath,
    int index,
    MenuItem expected,
    StateSetter dialogSetState,
  ) {
    final parent = _temporaryPages[parentPath];
    if (parent == null) return;
    final children = List<MenuItem>.from(parent.menuItem.children);
    if (index < 0 || index >= children.length) return;
    // The tree may have been rebuilt under us; only remove what was shown.
    if (children[index] != expected) return;
    _saveToHistory();
    setState(() {
      children.removeAt(index);
      _temporaryPages[parentPath] = parent.copyWith(
        menuItem: parent.menuItem.copyWith(children: children),
      );
      _updateCurrentJson();
    });
    dialogSetState(() {});
  }

  /// Renders a self-referencing child as a leaf page.
  /// E.g. the "IOs" entry has label "Diagnostics" with child {label: "IOs"}.
  /// The child is the actual clickable page that selects this entry for editing.
  Widget _buildSelfRefChild(
    MenuItem childItem,
    String mapKey,
    StateSetter dialogSetState,
    BuildContext dialogContext, {
    required int depth,
    required int reorderIndex,
  }) {
    final isSelected = _currentPage == mapKey;
    final page = _temporaryPages[mapKey];

    return Padding(
      key: ValueKey('selfref-$mapKey'),
      padding: const EdgeInsets.only(left: 20.0),
      child: ListTile(
        dense: true,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReorderableDragStartListener(
              index: reorderIndex,
              child:
                  const Icon(Icons.drag_handle, size: 20, color: Colors.grey),
            ),
            const SizedBox(width: 4),
            Icon(
              childItem.icon,
              color: isSelected
                  ? Theme.of(dialogContext).colorScheme.primary
                  : null,
            ),
          ],
        ),
        title: Text(
          childItem.label,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color:
                isSelected ? Theme.of(dialogContext).colorScheme.primary : null,
          ),
        ),
        selected: isSelected,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _startupToggle(mapKey, dialogSetState, dialogContext),
            if (page != null)
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                onPressed: () => _editSelfRefChild(
                    mapKey, childItem, dialogSetState, dialogContext),
                tooltip: 'Edit',
              ),
            IconButton(
              icon: const Icon(Icons.delete, size: 18),
              // This row is the section's own landing page, so deleting it
              // deletes the section — which the confirm used to hide by
              // naming the parent instead of the row that was tapped.
              onPressed: () => _deletePage(
                mapKey,
                dialogSetState,
                dialogContext,
                displayLabel: childItem.label,
                extraWarning: page == null
                    ? null
                    : 'This is the landing page of the "'
                        '${page.menuItem.label}" section, so the whole '
                        'section goes with it.',
              ),
              tooltip: 'Delete',
            ),
          ],
        ),
        onTap: () {
          setState(() => _currentPage = mapKey);
          Navigator.pop(dialogContext);
          // Opening a page is what stages the proposals left pending for it
          // when the editor was launched on another page.
          _stagePendingForCurrentPage();
        },
      ),
    );
  }

  /// A top-level destination the app registered itself. It has no page to
  /// select, edit or publish here — the row exists to be dragged into order
  /// (and, for routable destinations, to be picked as this station's startup
  /// page).
  Widget _buildAppItemNode(MenuItem item,
      {required int reorderIndex,
      StateSetter? dialogSetState,
      BuildContext? dialogContext}) {
    final movable =
        item.path != null && movableBuiltinPaths.contains(item.path);
    final trailing = <Widget>[
      // Built-in sections (Advanced) group but do not route, so they cannot
      // be a startup destination.
      if (!item.isNavigationSection &&
          item.path != null &&
          dialogSetState != null &&
          dialogContext != null)
        _startupToggle(item.path!, dialogSetState, dialogContext),
      if (movable && dialogSetState != null)
        IconButton(
          key: ValueKey('demote-builtin-${item.path}'),
          icon: const Icon(Icons.subdirectory_arrow_right, size: 18),
          tooltip: 'Move into Advanced',
          onPressed: () => _demoteBuiltin(item.path!, dialogSetState),
        ),
    ];
    return ListTile(
      key: ValueKey('app-item-${item.path}'),
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: reorderIndex,
            child: const Icon(Icons.drag_handle, size: 20, color: Colors.grey),
          ),
          const SizedBox(width: 4),
          Icon(item.icon),
        ],
      ),
      title: Text(item.label),
      subtitle: Text(item.path == _startupUrl
          ? 'Built-in — Startup page — this station'
          : 'Built-in — drag to reorder'),
      trailing: trailing.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }

  void _onReorderRoots(
    List<String> roots,
    int oldIndex,
    int newIndex,
    StateSetter dialogSetState,
  ) {
    if (oldIndex < newIndex) newIndex -= 1;
    _saveToHistory();
    setState(() {
      final movedName = roots[oldIndex];
      roots.removeAt(oldIndex);
      roots.insert(newIndex, movedName);
      // The full mixed order is what gets persisted; the per-page priorities
      // are kept in step so page-only consumers (getRootMenuItems) agree.
      _topLevelOrder = List.of(roots);
      _navOrderDirty = true;
      var pageIndex = 0;
      for (final path in roots) {
        final page = _temporaryPages[path];
        if (page == null) continue;
        _temporaryPages[path] = page.copyWith(navigationPriority: pageIndex++);
      }
      _updateCurrentJson();
    });
    dialogSetState(() {});
  }

  void _onReorderChildren(
    String parentName,
    int oldIndex,
    int newIndex,
    StateSetter dialogSetState,
  ) {
    if (oldIndex < newIndex) newIndex -= 1;
    _saveToHistory();
    setState(() {
      final parent = _temporaryPages[parentName]!;
      final children = List<MenuItem>.from(parent.menuItem.children);
      final moved = children.removeAt(oldIndex);
      children.insert(newIndex, moved);
      _temporaryPages[parentName] = parent.copyWith(
          menuItem: parent.menuItem.copyWith(children: children));
      // Update navigationPriority on each child page
      for (int i = 0; i < children.length; i++) {
        final childPath = children[i].path ?? '';
        final childPage = _temporaryPages[childPath];
        if (childPage != null) {
          _temporaryPages[childPath] =
              childPage.copyWith(navigationPriority: i);
        }
      }
      _updateCurrentJson();
    });
    dialogSetState(() {});
  }

  /// Edit a self-referencing child's properties (label, path, icon).
  /// Updates both the child MenuItem in the parent and the map entry.
  void _editSelfRefChild(
    String mapKey,
    MenuItem childItem,
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) {
    final page = _temporaryPages[mapKey]!;
    // Create a temporary AssetPage with the child's MenuItem for editing
    final childPage = page.copyWith(menuItem: childItem);

    showDialog(
      context: dialogContext,
      builder: (ctx) => StandardDialogFrame(
        title: 'Edit page',
        icon: Icons.edit,
        width: 440,
        child: SizedBox(
          width: 400,
          child: CreatePageWidget(
            initialPage: childPage,
            basePath: _buildBasePath(mapKey),
            // This row is the section's landing page and is keyed by the
            // section's own address; moving one without the other would only
            // detach it from the section it belongs to.
            allowAddressChange: false,
            onSave: (updatedPage) {
              _saveToHistory();
              setState(() {
                // Update the child MenuItem in the parent's children list
                final parentPage = _temporaryPages[mapKey]!;
                final updatedChildren = parentPage.menuItem.children.map((c) {
                  if (c.path == childItem.path) {
                    return c.copyWith(
                      label: updatedPage.menuItem.label,
                      path: updatedPage.menuItem.path,
                      icon: updatedPage.menuItem.icon,
                    );
                  }
                  return c;
                }).toList();
                _temporaryPages[mapKey] = parentPage.copyWith(
                  menuItem: parentPage.menuItem.copyWith(
                    children: updatedChildren,
                  ),
                  mirroringDisabled: updatedPage.mirroringDisabled,
                  zoomPanDisabled: updatedPage.zoomPanDisabled,
                  navigationPriority: updatedPage.navigationPriority,
                  published: updatedPage.published,
                );
                _updateCurrentJson();
              });
              dialogSetState(() {});
              return true;
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAddButtons(
    String? parentName,
    StateSetter dialogSetState,
    BuildContext dialogContext, {
    int depth = 0,
  }) {
    if (depth >= 3) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Page'),
          onPressed: () => _addItem(
            parentName: parentName,
            isSection: false,
            dialogSetState: dialogSetState,
            dialogContext: dialogContext,
          ),
        ),
        TextButton.icon(
          icon: const Icon(Icons.create_new_folder, size: 16),
          label: const Text('Section'),
          onPressed: () => _addItem(
            parentName: parentName,
            isSection: true,
            dialogSetState: dialogSetState,
            dialogContext: dialogContext,
          ),
        ),
      ],
    );
  }

  String _buildBasePath(String? parentPath) {
    if (parentPath == null) return '';
    final page = _temporaryPages[parentPath];
    if (page == null) return '';
    // Since all pages/sections now have paths, just use the parent's path
    return page.menuItem.path ?? '';
  }

  String? _findParentOf(String childPath) {
    for (final entry in _temporaryPages.entries) {
      if (entry.key != childPath &&
          entry.value.menuItem.children.any((c) => c.path == childPath)) {
        return entry.key;
      }
    }
    return null;
  }

  /// How deep a section may sit and still take children, matching the limit
  /// the "Add Page / Add Section" buttons already enforce.
  static const int _maxSectionDepth = 3;

  /// How close to the tree's edge a dragged row must get before the list
  /// starts scrolling, and the most it scrolls per frame at the very edge.
  static const double _autoScrollBand = 56;
  static const double _autoScrollMaxStep = 12;

  /// Scrolls the tree while a dragged row sits in the top or bottom band, so
  /// a section below the fold can still be reached. Speed ramps with how far
  /// into the band the pointer is.
  void _updateAutoScroll(Offset globalPosition) {
    final box =
        _treeViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_treeScrollController.hasClients) {
      _stopAutoScroll();
      return;
    }

    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = globalPosition.dy;

    double ratio = 0;
    if (y < top + _autoScrollBand) {
      ratio = -(top + _autoScrollBand - y) / _autoScrollBand;
    } else if (y > bottom - _autoScrollBand) {
      ratio = (y - (bottom - _autoScrollBand)) / _autoScrollBand;
    }
    _autoScrollStep = ratio.clamp(-1.0, 1.0) * _autoScrollMaxStep;

    if (_autoScrollStep == 0) {
      _stopAutoScroll();
    } else {
      _autoScrollTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _autoScrollTick(),
      );
    }
  }

  void _autoScrollTick() {
    if (!_treeScrollController.hasClients) {
      _stopAutoScroll();
      return;
    }
    final position = _treeScrollController.position;
    final target = (position.pixels + _autoScrollStep)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return; // Already against the end.
    _treeScrollController.jumpTo(target);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollStep = 0;
  }

  /// Makes a tree row draggable onto another section, and — when the row is a
  /// section — a drop target for other rows.
  ///
  /// The drag starts on a long press rather than immediately: the row sits
  /// inside the dialog's scrollable, and an immediate [Draggable] would eat
  /// the vertical drags that scroll the list. The drag handle keeps its own
  /// gesture, so it still reorders within the level.
  Widget _draggableRow({
    required String pageName,
    required AssetPage page,
    required int depth,
    required bool isSection,
    required Widget row,
    required StateSetter dialogSetState,
  }) {
    void setDragging(String? path) {
      if (path == null) _stopAutoScroll();
      setState(() => _dragPagePath = path);
      dialogSetState(() {});
    }

    final draggable = LongPressDraggable<String>(
      data: pageName,
      onDragStarted: () => setDragging(pageName),
      onDragUpdate: (details) => _updateAutoScroll(details.globalPosition),
      onDragEnd: (_) => setDragging(null),
      onDraggableCanceled: (_, __) => setDragging(null),
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(page.menuItem.icon, size: 18),
              const SizedBox(width: 8),
              Text(page.menuItem.label),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: row),
      child: row,
    );

    if (!isSection) return draggable;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          _moveBlockedReason(details.data, pageName, depth) == null,
      onAcceptWithDetails: (details) =>
          _movePage(details.data, pageName, dialogSetState),
      builder: (context, candidate, rejected) {
        final scheme = Theme.of(context).colorScheme;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: candidate.isEmpty ? null : scheme.primaryContainer,
            border: candidate.isEmpty
                ? null
                : Border.all(color: scheme.primary, width: 2),
          ),
          // Once a candidate hovers, this box has a background, and the row
          // inside is a ListTile -- which inks on the nearest Material, below
          // that background. Same trap as the proposal highlight. Transparent,
          // so the hover highlight is unchanged; the radius matches the box.
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: draggable,
          ),
        );
      },
    );
  }

  /// Drop area that un-nests an item.
  ///
  /// Always rendered, not just mid-drag: appearing on drag start would reflow
  /// the tree and slide the row out from under the pointer.
  Widget _buildTopLevelDropZone(StateSetter dialogSetState) {
    final dragging = _dragPagePath;
    final wouldTake = dragging != null && _findParentOf(dragging) != null;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => _findParentOf(details.data) != null,
      onAcceptWithDetails: (details) =>
          _movePage(details.data, null, dialogSetState),
      builder: (context, candidate, rejected) {
        final scheme = Theme.of(context).colorScheme;
        final active = candidate.isNotEmpty;
        return Container(
          height: 40,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active ? scheme.primaryContainer : null,
            border: Border.all(
              color:
                  active || wouldTake ? scheme.primary : scheme.outlineVariant,
              width: active ? 2 : 1,
            ),
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.north, size: 16, color: scheme.outline),
                const SizedBox(width: 8),
                Text(
                  wouldTake || active
                      ? 'Drop here to move to the top level'
                      : 'Top level',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Every section in the tree, in the order the Pages dialog renders them,
  /// with the depth used to indent them in the move picker.
  List<({String path, String label, IconData icon, int depth})>
      _collectSectionTargets() {
    final targets = <({String path, String label, IconData icon, int depth})>[];
    final seen = <String>{};

    void walk(String path, int depth) {
      if (!seen.add(path)) return;
      final page = _temporaryPages[path];
      if (page == null) return;
      if (page.menuItem.isNavigationSection) {
        targets.add((
          path: path,
          label: page.menuItem.label,
          icon: page.menuItem.icon,
          depth: depth,
        ));
      }
      for (final child in page.menuItem.children) {
        final childPath = child.path;
        // Self-references are the section's own landing page, not a child.
        if (childPath == null || childPath.isEmpty || childPath == path) {
          continue;
        }
        walk(childPath, depth + 1);
      }
    }

    for (final root in _getRootPageNames()) {
      walk(root, 0);
    }
    return targets;
  }

  /// How many levels sit below [pagePath] — 0 for a page or empty section.
  /// Cycle-safe: a self-referencing or looping tree returns what it has
  /// walked so far rather than recursing forever.
  int _subtreeHeight(String pagePath, [Set<String>? seen]) {
    final visited = seen ?? <String>{};
    if (!visited.add(pagePath)) return 0;
    var height = 0;
    for (final child in _temporaryPages[pagePath]?.menuItem.children ??
        const <MenuItem>[]) {
      final path = child.path;
      if (path == null || path.isEmpty || path == pagePath) continue;
      if (!_temporaryPages.containsKey(path)) continue;
      final below = 1 + _subtreeHeight(path, visited);
      if (below > height) height = below;
    }
    return height;
  }

  /// Why [targetPath] cannot receive [pagePath], or null when it can.
  String? _moveBlockedReason(String pagePath, String targetPath, int depth) {
    if (targetPath == pagePath) return 'This is the item being moved';
    if (targetPath == _findParentOf(pagePath)) return 'Already here';
    if (PageManager.isDescendantOf(_temporaryPages,
        ancestor: pagePath, candidate: targetPath)) {
      return 'Inside the item being moved';
    }
    // A section brings its own levels with it, so the limit has to be checked
    // against the deepest page inside it — not just where the section lands.
    // Without this a three-deep section could be dropped two levels down and
    // end up nested past where the Add buttons will even appear.
    final height = _subtreeHeight(pagePath);
    if (depth + height >= _maxSectionDepth) {
      return height == 0
          ? 'Nesting limit reached'
          : 'Too deep for what you are moving';
    }
    return null;
  }

  /// Destination picker for moving a page or section somewhere else.
  ///
  /// A flat, indented list rather than drag-and-drop: the Pages dialog already
  /// uses nested [ReorderableListView]s for ordering within a level, and those
  /// swallow drags, so cross-section moves get their own explicit gesture that
  /// also works on a touch panel.
  void _showMoveDialog(
    String pagePath,
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) {
    final page = _temporaryPages[pagePath];
    if (page == null) return;
    final isRoot = _findParentOf(pagePath) == null;
    final targets = _collectSectionTargets();

    showDialog(
      context: dialogContext,
      builder: (ctx) => StandardDialogFrame(
        title: 'Move "${page.menuItem.label}"',
        subtitle: 'Pick the section it should live under. The address stays '
            'the same, so links to it keep working.',
        icon: Icons.drive_file_move_outline,
        width: 440,
        height: 460,
        // The list scrolls itself; an outer scroll would unbound its height.
        scrollable: false,
        child: ListView(
          children: [
            _buildMoveTarget(
              ctx: ctx,
              icon: Icons.north,
              label: 'Top level',
              depth: 0,
              blockedReason: isRoot ? 'Already here' : null,
              onMove: () => _movePage(pagePath, null, dialogSetState),
            ),
            if (targets.isNotEmpty) const Divider(height: 1),
            for (final target in targets)
              _buildMoveTarget(
                ctx: ctx,
                icon: target.icon,
                label: target.label,
                depth: target.depth,
                blockedReason:
                    _moveBlockedReason(pagePath, target.path, target.depth),
                onMove: () => _movePage(pagePath, target.path, dialogSetState),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoveTarget({
    required BuildContext ctx,
    required IconData icon,
    required String label,
    required int depth,
    required String? blockedReason,
    required VoidCallback onMove,
  }) {
    final enabled = blockedReason == null;
    return Padding(
      padding: EdgeInsets.only(left: depth * 20.0),
      child: ListTile(
        dense: true,
        enabled: enabled,
        leading: Icon(icon),
        title: Text(label),
        subtitle: blockedReason == null ? null : Text(blockedReason),
        onTap: enabled
            ? () {
                Navigator.pop(ctx);
                onMove();
              }
            : null,
      ),
    );
  }

  /// Applies a move and reports it, since the tree may scroll the moved item
  /// out of view.
  void _movePage(
    String pagePath,
    String? newParentPath,
    StateSetter dialogSetState,
  ) {
    final label = _temporaryPages[pagePath]?.menuItem.label ?? pagePath;
    final destination = newParentPath == null
        ? 'the top level'
        : '"${_temporaryPages[newParentPath]?.menuItem.label ?? newParentPath}"';

    _saveToHistory();
    setState(() {
      _temporaryPages = PageManager.movePage(
        _temporaryPages,
        pagePath: pagePath,
        newParentPath: newParentPath,
      );
      _updateCurrentJson();
    });
    dialogSetState(() {});

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Moved "$label" to $destination.')),
    );
  }

  void _addItem({
    required String? parentName,
    required bool isSection,
    required StateSetter dialogSetState,
    required BuildContext dialogContext,
  }) {
    showDialog(
      context: dialogContext,
      builder: (ctx) => StandardDialogFrame(
        title: isSection ? 'Add section' : 'Add page',
        icon: isSection ? Icons.create_new_folder : Icons.note_add,
        width: 440,
        child: SizedBox(
          width: 400,
          child: CreatePageWidget(
            isSection: isSection,
            basePath: _buildBasePath(parentName),
            onSave: (page) {
              final newPath = page.menuItem.path ?? '';
              if (_temporaryPages.containsKey(newPath)) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                        'A page with path "$newPath" already exists. Please choose a different name.'),
                  ),
                );
                return false;
              }
              _saveToHistory();
              setState(() {
                // Auto-assign priority: put at end of its level
                final int priority;
                if (parentName != null) {
                  final parent = _temporaryPages[parentName];
                  priority = parent?.menuItem.children.length ?? 0;
                } else {
                  priority = _getRootPageNames().length;
                }
                final pageWithPriority =
                    page.copyWith(navigationPriority: priority);
                _temporaryPages[newPath] = pageWithPriority;
                // Add as child of parent if specified
                if (parentName != null) {
                  final parent = _temporaryPages[parentName];
                  if (parent != null) {
                    final updatedChildren =
                        List<MenuItem>.from(parent.menuItem.children)
                          ..add(pageWithPriority.menuItem);
                    _temporaryPages[parentName] = parent.copyWith(
                      menuItem:
                          parent.menuItem.copyWith(children: updatedChildren),
                    );
                  }
                }
                if (!isSection) {
                  _currentPage = newPath;
                }
                _updateCurrentJson();
              });
              dialogSetState(() {});
              return true;
            },
          ),
        ),
      ),
    );
  }

  void _editPage(
    String pagePath,
    AssetPage page,
    StateSetter dialogSetState,
    BuildContext dialogContext,
  ) {
    final isSection = page.menuItem.isNavigationSection;
    showDialog(
      context: dialogContext,
      builder: (ctx) => StandardDialogFrame(
        title: 'Edit',
        icon: Icons.edit,
        width: 440,
        child: SizedBox(
          width: 400,
          child: CreatePageWidget(
            initialPage: page,
            isSection: isSection,
            basePath: _buildBasePath(_findParentOf(pagePath)),
            addressChangeNote: _startupUrl == pagePath
                ? "This station's startup page points here and will follow the "
                    'move.'
                : null,
            onSave: (updatedPage) {
              final newPath = updatedPage.menuItem.path ?? '';
              if (newPath != pagePath && _temporaryPages.containsKey(newPath)) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                        'A page with path "$newPath" already exists. Please choose a different name.'),
                  ),
                );
                return false;
              }
              _saveToHistory();
              setState(() {
                if (newPath != pagePath) {
                  _temporaryPages.remove(pagePath);
                  // Update parent references
                  _updateChildPathInParents(
                      pagePath, newPath, updatedPage.menuItem);
                  if (_currentPage == pagePath) {
                    _currentPage = newPath;
                  }
                  // The station's startup page is stored as an address, so a
                  // page that moves has to take the setting with it or the
                  // next boot lands on a route that no longer exists.
                  if (_startupUrl == pagePath) {
                    _retargetStartupUrl(newPath);
                  }
                }
                _temporaryPages[newPath] = updatedPage;
                _updateCurrentJson();
              });
              dialogSetState(() {});
              return true;
            },
          ),
        ),
      ),
    );
  }

  void _updateChildPathInParents(
      String oldPath, String newPath, MenuItem newMenuItem) {
    final updates = <String, AssetPage>{};
    for (final entry in _temporaryPages.entries) {
      final page = entry.value;
      final updated = _updatePathInChildren(
          page.menuItem.children, oldPath, newPath, newMenuItem);
      if (updated != null) {
        updates[entry.key] =
            page.copyWith(menuItem: page.menuItem.copyWith(children: updated));
      }
    }
    _temporaryPages.addAll(updates);
  }

  List<MenuItem>? _updatePathInChildren(List<MenuItem> children, String oldPath,
      String newPath, MenuItem newMenuItem) {
    bool changed = false;
    final result = children.map((child) {
      MenuItem updated = child;
      if (child.path == oldPath) {
        changed = true;
        updated = child.copyWith(
          label: newMenuItem.label,
          path: newPath,
          icon: newMenuItem.icon,
          isSection: newMenuItem.isSection,
        );
      }
      final subUpdated = _updatePathInChildren(
          updated.children, oldPath, newPath, newMenuItem);
      if (subUpdated != null) {
        changed = true;
        updated = updated.copyWith(children: subUpdated);
      }
      return updated;
    }).toList();
    return changed ? result : null;
  }

  /// Every page beneath [pagePath], excluding itself. Cycle-safe, so bad
  /// stored data cannot hang the confirm dialog.
  List<String> _descendantsOf(String pagePath) {
    final found = <String>[];
    final seen = <String>{pagePath};
    final queue = <String>[pagePath];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final child in _temporaryPages[current]?.menuItem.children ??
          const <MenuItem>[]) {
        final path = child.path;
        // A section listing itself is its own landing page, not a child.
        if (path == null || path.isEmpty || path == current) continue;
        if (!seen.add(path)) continue;
        if (_temporaryPages.containsKey(path)) found.add(path);
        queue.add(path);
      }
    }
    return found;
  }

  /// Spells out what pressing Delete costs, so nothing goes without warning:
  /// how many assets are on the page, what happens to a section's contents,
  /// and whether this station's startup setting is about to be reset.
  String _deleteWarning(String pagePath, AssetPage page) {
    final lines = <String>[];
    final isSection = page.menuItem.isNavigationSection;
    final children = isSection ? _descendantsOf(pagePath) : const <String>[];

    if (children.isNotEmpty) {
      final n = children.length;
      lines.add('This section holds $n ${n == 1 ? 'page' : 'pages'}. '
          'They are not deleted — they move to the top level.');
    }

    final assets = page.assets.length;
    if (assets > 0) {
      lines.add('$assets ${assets == 1 ? 'asset' : 'assets'} on it '
          '${assets == 1 ? 'is' : 'are'} deleted with it.');
    }

    if (_startupUrl == pagePath) {
      lines.add("This station starts on this page; the setting resets to "
          '$startupUrlDefault.');
    }

    lines.add('Undo (Ctrl+Z) brings it back until you save.');
    return lines.join('\n\n');
  }

  void _deletePage(
    String pagePath,
    StateSetter dialogSetState,
    BuildContext dialogContext, {
    String? displayLabel,
    String? extraWarning,
  }) {
    final page = _temporaryPages[pagePath];
    final displayName =
        displayLabel ?? page?.menuItem.label ?? pagePath;
    final warning = [
      if (extraWarning != null) extraWarning,
      if (page != null) _deleteWarning(pagePath, page),
    ].join('\n\n');

    showConfirmDialog(
      context: dialogContext,
      title: 'Delete',
      message: 'Delete "$displayName"?\n\n$warning',
      confirmLabel: 'Delete',
      destructive: true,
    ).then((confirmed) {
      if (!confirmed) return;
      final startupWasHere = _startupUrl == pagePath;
      _saveToHistory();
      setState(() {
        _temporaryPages.remove(pagePath);
        // Remove from parent children lists
        _removeChildFromParents(pagePath);
        if (_currentPage == pagePath) {
          _currentPage = _temporaryPages.keys.firstOrNull;
        }
        // Leaving the setting pointed at a deleted address boots the station
        // onto a route that no longer resolves.
        if (startupWasHere) _retargetStartupUrl(startupUrlDefault);
        _updateCurrentJson();
      });
      dialogSetState(() {});
      if (startupWasHere && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted "$displayName". This station\'s startup '
                'page reset to $startupUrlDefault.'),
          ),
        );
      }
    });
  }

  void _removeChildFromParents(String path) {
    final updates = <String, AssetPage>{};
    for (final entry in _temporaryPages.entries) {
      final page = entry.value;
      final updated = _removeFromChildren(page.menuItem.children, path);
      if (updated != null) {
        updates[entry.key] =
            page.copyWith(menuItem: page.menuItem.copyWith(children: updated));
      }
    }
    _temporaryPages.addAll(updates);
  }

  List<MenuItem>? _removeFromChildren(List<MenuItem> children, String path) {
    bool changed = false;
    final result = <MenuItem>[];
    for (final child in children) {
      if (child.path == path) {
        changed = true;
        continue;
      }
      final subUpdated = _removeFromChildren(child.children, path);
      if (subUpdated != null) {
        changed = true;
        result.add(child.copyWith(children: subUpdated));
      } else {
        result.add(child);
      }
    }
    return changed ? result : null;
  }
}

class _PaletteItem extends StatelessWidget {
  final Type assetType;
  final Asset asset;

  const _PaletteItem({
    required this.assetType,
    required this.asset,
  });

  @override
  Widget build(BuildContext context) {
    return Draggable<Type>(
      data: assetType,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 80,
          height: 80,
          child: Opacity(
            opacity: 0.7,
            child: asset.build(context),
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: _buildThumbnail(context),
      ),
      child: _buildThumbnail(context),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        children: [
          Expanded(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: 80,
                height: 80,
                child: ClipRect(
                  child: IgnorePointer(
                    child: asset.build(context),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            asset.displayName,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class SelectionBoxPainter extends CustomPainter {
  final Offset start;
  final Offset current;

  SelectionBoxPainter({required this.start, required this.current});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
      ..style = PaintingStyle.fill;

    final rect = Rect.fromPoints(start, current);
    canvas.drawRect(rect, paint);

    final borderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(SelectionBoxPainter oldDelegate) {
    return start != oldDelegate.start || current != oldDelegate.current;
  }
}

enum _LeaveChoice { save, discard, stay }

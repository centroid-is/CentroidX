import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderConstrainedBox, BoxHitTestResult, BoxHitTestEntry;
import 'package:logger/logger.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:tfc_dart/core/preferences.dart' show PreferencesApi;
import 'package:tfc/page_creator/page.dart' show AssetPage;

import '../chat/asset_context_menu.dart';
import '../core/feature_flags.dart';
import '../widgets/proposal_visual.dart';
import '../providers/page_manager.dart';
import '../providers/preferences.dart' show localPreferencesProvider;
import '../providers/state_man.dart';
import '../theme.dart' show HmiStateColors;
import '../page_creator/assets/common.dart'; // your Asset, Coordinates, RelativeSize, TextPos, etc.
import '../page_creator/assets/link_anchors.dart';
import '../widgets/base_scaffold.dart';
import '../widgets/hit_boundary.dart';
import '../widgets/panes/side_pane.dart';
import '../widgets/zoomable_canvas.dart';

part 'page_view.g.dart';

final _log = Logger(
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    lineLength: 120,
    colors: true,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
  ),
);

@JsonSerializable()
class AssetStackConfig {
  bool xMirror;
  bool yMirror;
  AssetStackConfig({this.xMirror = false, this.yMirror = false});
  factory AssetStackConfig.fromJson(Map<String, dynamic> json) =>
      _$AssetStackConfigFromJson(json);
  Map<String, dynamic> toJson() => _$AssetStackConfigToJson(this);
}

Matrix4 _buildTransform(bool xMirror, bool yMirror) {
  return Matrix4.identity()..scale(xMirror ? -1.0 : 1.0, yMirror ? -1.0 : 1.0);
}

// Conditionally wraps the editor's selection chrome in a bordered Container.
// A Container with a BoxDecoration hit-tests opaque for its full rect (even
// when only a border is set) because BoxDecoration.hitTest returns true
// inside any rectangular shape regardless of fillColor — that would swallow
// runtime-mode primary taps before they reach the asset's own
// GestureDetectors. Only paint the border when actually selected.
/// Places chrome over an asset in that asset's own rotated frame.
///
/// The asset visual rotates internally (each asset reads `coordinates.angle`),
/// so anything drawn over it -- the selection border, the AI-proposal outline
/// -- must be rotated separately or it sits askew across a turned asset. The
/// `OverflowBox` lets the unrotated size escape the parent's tight AABB
/// constraints; `Transform.rotate` also transforms hit-tests, so a
/// `GestureDetector` inside follows the rotated visual.
///
/// Shared by the selection and proposal overlays so the two cannot drift.
Widget _rotatedAssetFrame({
  required double angle,
  required double width,
  required double height,
  required Widget child,
}) {
  return OverflowBox(
    minWidth: 0,
    minHeight: 0,
    maxWidth: double.infinity,
    maxHeight: double.infinity,
    child: Transform.rotate(
      angle: angle,
      alignment: Alignment.center,
      child: SizedBox(width: width, height: height, child: child),
    ),
  );
}

Widget _wrapWithSelectionBorder({
  required bool isSelected,
  required Widget child,
}) {
  if (!isSelected) return child;
  return Container(
    // Keyed so tests can count the selection off what is actually painted
    // rather than reaching into editor state.
    key: selectionBorderKey,
    decoration: BoxDecoration(
      border: Border.all(color: Colors.blue, width: 2),
    ),
    child: child,
  );
}

/// Marks the border drawn around a selected asset. One per selected asset.
const Key selectionBorderKey = ValueKey('asset-selection-border');

/// Computes the top-left offset for the label given the asset center, its size,
/// the label size, and the desired position.
///
/// Exposed for unit testing (regression for the inside-label bug where
/// `TextPos.inside` fell through to the right-side default).
@visibleForTesting
Offset labelOffset(
  Offset center,
  Size assetSize,
  Size textSize,
  TextPos pos, [
  double spacing = 8,
]) {
  final halfW = assetSize.width / 2;
  final halfH = assetSize.height / 2;
  switch (pos) {
    case TextPos.above:
      return Offset(
        center.dx - textSize.width / 2,
        center.dy - halfH - spacing - textSize.height,
      );
    case TextPos.below:
      return Offset(
        center.dx - textSize.width / 2,
        center.dy + halfH + spacing,
      );
    case TextPos.left:
      return Offset(
        center.dx - halfW - spacing - textSize.width,
        center.dy - textSize.height / 2,
      );
    case TextPos.inside:
      // Centre the label inside the asset's bounding rect. Used by
      // buttons / controls where the label is a face caption rather
      // than an external annotation.
      return Offset(
        center.dx - textSize.width / 2,
        center.dy - textSize.height / 2,
      );
    case TextPos.right:
      return Offset(
        center.dx + halfW + spacing,
        center.dy - textSize.height / 2,
      );
  }
}

class AssetStack extends ConsumerStatefulWidget {
  final List<Asset> assets;
  final BoxConstraints constraints;
  final void Function(Asset asset)? onTap;

  /// Double tap on an asset in edit mode. Registering it costs single taps
  /// the double-tap disambiguation window before [onTap] fires, so it is only
  /// wired up when a host actually supplies it — the runtime view never pays.
  final void Function(Asset asset)? onDoubleTap;
  final void Function(Asset asset, DragUpdateDetails details)? onPanUpdate;
  final void Function(Asset asset, DragStartDetails details)? onPanStart;

  /// Secondary tap (right-click) on an asset in edit mode. When supplied the
  /// host builds the whole context menu, so it can offer editing actions
  /// alongside the AI ones. Falls back to the AI-only menu when null.
  final void Function(Asset asset, Offset globalPosition)? onSecondaryTap;
  final bool absorb;
  final Set<Asset> selectedAssets;
  final bool mirroringDisabled;

  /// Assets that were proposed by AI. When non-empty, these assets are
  /// rendered with a dashed amber border and AI sparkle badge.
  final Set<Asset> proposedAssets;

  const AssetStack({
    Key? key,
    required this.assets,
    required this.constraints,
    this.onTap,
    this.onDoubleTap,
    this.onPanUpdate,
    this.onPanStart,
    this.onSecondaryTap,
    this.absorb = false,
    required this.selectedAssets,
    required this.mirroringDisabled,
    this.proposedAssets = const {},
  }) : super(key: key);

  @override
  ConsumerState<AssetStack> createState() => _AssetStackState();
}

/// A [SizedBox] whose hit test does not clamp to its own bounds.
///
/// Assets rotate INTERNALLY (`LayoutRotatedBox` reads `coordinates.angle`)
/// and paint out of their unrotated w×h rect into the surrounding AABB. A
/// plain [SizedBox] rejects any hit outside the unrotated rect before the
/// asset's own rotation-aware hit test can consider it, which truncated a
/// rotated asset's tappable area to the overlap sliver between the rotated
/// visual and the unrotated rect. This box lays out exactly like a
/// [SizedBox] but forwards every position to its child — the child still
/// accepts or rejects against its own (rotation-aware) geometry, so the
/// effective hit area is the visible glyph, never more.
class _HitPermissiveSizedBox extends SingleChildRenderObjectWidget {
  final double width;
  final double height;

  const _HitPermissiveSizedBox({
    required this.width,
    required this.height,
    super.child,
  });

  BoxConstraints get _additionalConstraints =>
      BoxConstraints.tightFor(width: width, height: height);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderHitPermissiveConstrainedBox(
      additionalConstraints: _additionalConstraints,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHitPermissiveConstrainedBox renderObject,
  ) {
    renderObject.additionalConstraints = _additionalConstraints;
  }
}

class _RenderHitPermissiveConstrainedBox extends RenderConstrainedBox {
  _RenderHitPermissiveConstrainedBox({required super.additionalConstraints});

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Deliberately no `size.contains(position)` gate — see the widget doc.
    // The child decides; we only record ourselves on the path when it hits.
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}

class _AssetStackState extends ConsumerState<AssetStack> {
  // `late` so `ref` is available by the time it is read; `final` so the store
  // is resolved once per mount rather than per build. Read through the
  // provider rather than the factory because a `ref` exists here — spec §6's
  // one-construction-site rule, enforced by
  // `scripts/check-preferences-construction.sh`.
  late final PreferencesApi prefs = ref.read(localPreferencesProvider);

  /// Read once per mount, not once per build. The stack rebuilds on every
  /// drag tick while an asset is moved, and handing FutureBuilder a fresh
  /// future each time meant a preferences read — and the extra rebuild its
  /// completion schedules — per pointer event. Nothing writes this key after
  /// startup, so a per-mount read loses nothing.
  late final Future<AssetStackConfig> _configFuture =
      prefs.getString('asset_stack_config').then((value) {
    if (value == null) {
      final cfg = AssetStackConfig();
      prefs.setString('asset_stack_config', jsonEncode(cfg.toJson()));
      return cfg;
    }
    return AssetStackConfig.fromJson(jsonDecode(value));
  });

  /// Label sizes by (text, style). Measuring text is the expensive part of
  /// laying a label out, and during a drag neither the text nor its style
  /// changes — only the position does — so the measure from the first frame
  /// serves every following tick.
  final Map<(String, TextStyle), Size> _labelSizeCache = {};

  /// The shape [asset] takes taps on, in that shape's own coordinates, with
  /// the box it was measured in — or null when the asset publishes none.
  ///
  /// Walks the canvas subtree for the [ObjectKey] this stack hangs on each
  /// asset's `Positioned` — the same route the page editor takes to measure
  /// an asset — and then down for an [AssetHitShape]. Only assets whose hit
  /// test is a path publish one; the rest take taps on their whole face, and
  /// [_OpenPaneMark] draws that face.
  ({Path path, RenderBox box})? _hitShapeOf(Object asset) {
    if (!mounted) return null;
    final key = ObjectKey(asset);
    Element? positioned;
    void findPositioned(Element element) {
      if (positioned != null) return;
      if (element.widget.key == key) {
        positioned = element;
        return;
      }
      element.visitChildElements(findPositioned);
    }

    context.visitChildElements(findPositioned);
    final root = positioned;
    if (root == null) return null;

    ({Path path, RenderBox box})? found;
    void findShape(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is AssetHitShape) {
        // The published path is in the coordinates of the widget it wraps,
        // and that widget's box is the first render object below here.
        // Resolved here and nowhere else: this runs when a pane opens, and
        // the asset is rebuilt far more often than that.
        final ro = element.findRenderObject();
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          found = (path: widget.shape(), box: ro);
        }
        return;
      }
      element.visitChildElements(findShape);
    }

    root.visitChildElements(findShape);
    return found;
  }

  Size _measureLabel(String text, TextStyle style) {
    if (_labelSizeCache.length > 512) _labelSizeCache.clear();
    return _labelSizeCache.putIfAbsent((text, style), () {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final size = tp.size;
      tp.dispose();
      return size;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This will trigger a rebuild when the substitutions change
    ref.watch(substitutionsChangedProvider);

    final W = widget.constraints.maxWidth;
    final H = widget.constraints.maxHeight;

    return FutureBuilder<AssetStackConfig>(
      future: _configFuture,
      builder: (context, snap) {
        final cfg = snap.data ?? AssetStackConfig();

        // Effective flags rather than writes back into cfg: the config now
        // lives for the whole mount, so a build must not edit it in place.
        final xMirror = !widget.mirroringDisabled && cfg.xMirror;
        final yMirror = !widget.mirroringDisabled && cfg.yMirror;

        // We'll accumulate all Positioned children here
        final positionedChildren = <Widget>[];

        // Where each asset ended up, for the mark that says which one the
        // open side pane is about. Built here rather than measured later
        // because this loop already has the geometry, and identity-keyed
        // because two assets of a type are equal only by identity.
        final frames = Map<Object, _AssetFrame>.identity();

        for (final asset in widget.assets) {
          // 0) An asset whose box depends on the rest of the page answers
          //    with one; everything else sits where it was dropped. Read into
          //    locals rather than written back into the config -- see
          //    [Asset.boxOn], and the note above about not editing a config
          //    during a build.
          final derived = asset.boxOn(widget.assets, Size(W, H));
          final baseX = derived?.center.dx ?? asset.coordinates.x;
          final baseY = derived?.center.dy ?? asset.coordinates.y;
          final baseW = derived?.width ?? asset.size.width;
          final baseH = derived?.height ?? asset.size.height;

          // 1) normalized coords with optional mirroring
          final fx = xMirror ? 1 - baseX : baseX;
          final fy = yMirror ? 1 - baseY : baseY;

          // 2) canvas-pixel center point
          final cx = fx * W;
          final cy = fy * H;
          final center = Offset(cx, cy);

          final assetW = baseW * W;
          final assetH = baseH * H;
          final assetSize = Size(assetW, assetH);
          final halfW = assetW / 2;
          final halfH = assetH / 2;

          final textScaler = TextScaler.linear(math.min(assetW, assetH) / 25);
          // Build the label style starting from the ambient DefaultTextStyle
          // and overlaying:
          //   - the scaled font size (preserves the pre-existing behaviour
          //     that labels grow with the asset's bounding box), and
          //   - the per-asset `labelColor` override when non-null
          //     (e.g. `ButtonConfig.textColor`). A null override leaves the
          //     ambient color untouched so assets without a configurable
          //     label color render byte-for-byte as before.
          final ambientStyle = DefaultTextStyle.of(context).style;
          var labelStyle = ambientStyle.copyWith(
            fontSize: textScaler.scale(ambientStyle.fontSize ?? 16),
          );
          if (asset.labelColor != null) {
            labelStyle = labelStyle.copyWith(color: asset.labelColor);
          }

          // 4) measure text size if any
          //
          // An asset that hides its label measures as if it had none, so the
          // rest of the layout does not reserve room for a caption nobody
          // asked for.
          final paintsLabel =
              asset.showLabel && asset.text != null && asset.text!.isNotEmpty;
          Size textSize = Size.zero;
          if (paintsLabel) {
            textSize = _measureLabel(asset.text!, labelStyle);
          }

          final isProposed = widget.proposedAssets.contains(asset);

          // A) add the asset widget itself
          //
          // Layering for rotation correctness:
          //   - The asset visual (asset.build) rotates internally via its
          //     own `LayoutRotatedBox`/`Transform.rotate` (each asset reads
          //     `coordinates.angle`). We do NOT wrap the visual in an outer
          //     Transform.rotate here -- that would double-rotate.
          //   - The selection-border container and the editor's
          //     GestureDetector live in a SIBLING overlay that IS wrapped
          //     in `Transform.rotate(angle, alignment: Alignment.center)`.
          //     This makes the blue selection rectangle rotate with the
          //     visual, and (because Transform.rotate transforms hit-tests
          //     by default) the GestureDetector's hit area follows the
          //     rotated visual instead of the unrotated bounding box.
          //
          // See test/page_creator/selection_rotation_test.dart for the
          // regression contract.
          final angleRadians = (asset.coordinates.angle ?? 0.0) * math.pi / 180;
          final isSelected = widget.selectedAssets.contains(asset);

          // Compute the rotated AABB (axis-aligned bounding box) so the
          // outer Positioned is large enough for taps on the rotated
          // visual to reach our hit-test subtree. Without this, Stack
          // clips hit-tests at each child's layout bounds and operator
          // clicks on the visible glyph miss when the rotation pushes
          // pixels outside the unrotated rect.
          final cosA = math.cos(angleRadians).abs();
          final sinA = math.sin(angleRadians).abs();
          final aabbW = assetW * cosA + assetH * sinA;
          final aabbH = assetW * sinA + assetH * cosA;
          final halfAabbW = aabbW / 2;
          final halfAabbH = aabbH / 2;

          final frame = _AssetFrame(
            center: center,
            size: assetSize,
            aabb: Size(aabbW, aabbH),
            angle: angleRadians,
          );
          frames[asset] = frame;
          // A composite asset's slices ride their parent's frame: the frame
          // is only the coarse "is it still here / did it move" tracking for
          // the mark, and a slice moves exactly when its rack does. The
          // slice's own outline comes from the shape probe, not from here.
          for (final sub in asset.childAssets) {
            frames[sub] = frame;
          }

          positionedChildren.add(
            Positioned(
              // Keyed by identity so a z-order change (send to back / bring
              // to front) moves the existing element instead of rebuilding
              // every asset at its new index — asset subtrees hold live
              // state (subscriptions, futures) that a rebuild would restart.
              key: ObjectKey(asset),
              left: cx - halfAabbW,
              top: cy - halfAabbH,
              width: aabbW,
              height: aabbH,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  // 1) The asset visual. The asset's own `build()` handles
                  //    internal rotation; wrapping it again in
                  //    `Transform.rotate(angle)` would double-rotate, so
                  //    only the mirror transform lives here. The SizedBox
                  //    keeps the unrotated visual constraints stable; the
                  //    asset's internal rotation paints out into the
                  //    surrounding AABB. `OverflowBox` lets the SizedBox
                  //    escape the Stack's tight AABB constraints (Stack
                  //    would otherwise shrink the 40x10 visual to fit the
                  //    10x40 AABB).
                  // The RepaintBoundary sits OUTSIDE the OverflowBox (sized
                  // to the AABB) rather than hugging the asset: hugging it
                  // both let the rotated overflow painting escape the
                  // boundary and clamped hit tests to the unrotated rect
                  // (RenderProxyBox.hitTest rejects positions outside its
                  // own size).
                  RepaintBoundary(
                    child: OverflowBox(
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      // NOT a plain SizedBox: a rotated asset paints out
                      // into the AABB, and a SizedBox rejects hits outside
                      // its unrotated w×h rect before the asset's
                      // rotation-aware hit test
                      // (`_RenderLayoutRotatedBox.hitTest`) gets a say —
                      // truncating a rotated sensor's tappable area to the
                      // sliver where the rotated visual and the unrotated
                      // rect overlap. The permissive box lays out
                      // identically but forwards every position to the
                      // child, which still clamps to its own (rotated)
                      // geometry.
                      child: _HitPermissiveSizedBox(
                        width: assetW,
                        height: assetH,
                        child: Transform(
                          alignment: Alignment.center,
                          // Unrotated assets skip the flip so their text
                          // stays readable on mirrored stations; chiral
                          // glyphs (conveyor turns) opt back in via
                          // [Asset.mirrorsWithPage] and counter-mirror
                          // their own text (see [AssetMirrorScope]).
                          transform: asset.coordinates.angle != null ||
                                  asset.mirrorsWithPage
                              ? _buildTransform(xMirror, yMirror)
                              : Matrix4.identity(),
                          child: widget.absorb
                              // In editor mode the asset's own
                              // GestureDetectors must NOT fire -- the
                              // editor's overlay GestureDetector (below) is
                              // the single tap source. We use IgnorePointer
                              // because the overlay sits on top in the
                              // Stack and would otherwise compete with the
                              // asset's internal gestures.
                              // AssetEditModeScope lets assets that render
                              // nothing at runtime (idle alarm beacons) draw
                              // an editor-only placeholder instead of
                              // disappearing from the canvas.
                              ? IgnorePointer(
                                  child: AssetEditModeScope(
                                      child: asset.build(context)))
                              // Everything the asset builds sits under the
                              // scope, so when it opens its pane from its
                              // own build context the pane host learns
                              // which asset that pane is about — and
                              // [_OpenPaneMark] can say so on the mimic
                              // without a single asset opting in. Runtime
                              // only: in the editor the asset's gestures
                              // are ignored anyway, and the config pane is
                              // opened by the editor, over an asset it
                              // already draws a selection border around.
                              : SidePaneSubject(
                                  subject: asset,
                                  // Through a Builder so the context the
                                  // asset builds with is itself inside the
                                  // scope. An asset that opens its pane with
                                  // the context handed to `build` — rather
                                  // than one from a widget of its own — is
                                  // then marked like any other, and
                                  // `showSidePane` measures that asset's box
                                  // for `avoidRect` instead of the whole
                                  // canvas's.
                                  child: Builder(builder: asset.build)),
                        ),
                      ),
                    ),
                  ),
                  // 2) Rotated overlay carrying the selection border and
                  //    the editor's GestureDetector. Transform.rotate
                  //    rotates BOTH the painted border AND the hit-test
                  //    region (default `transformHitTests: true`) so the
                  //    GestureDetector hit area tracks the rotated visual
                  //    instead of the unrotated bounding rect.
                  _rotatedAssetFrame(
                    angle: angleRadians,
                    width: assetW,
                    height: assetH,
                    // Container with a BoxDecoration hit-tests opaque for
                    // its full bounds even when only a border is set
                    // (BoxDecoration.hitTest returns true inside any
                    // rectangular shape regardless of fill). In runtime
                    // mode the overlay's inner GestureDetector is
                    // translucent so primary taps fall through to the
                    // asset's own GestureDetectors — but the wrapping
                    // Container would still consume the hit. Only wrap
                    // in a Container when there is an actual border to
                    // paint (i.e. when selected); otherwise the chrome
                    // is just the bare GestureDetector.
                    child: _wrapWithSelectionBorder(
                      isSelected: isSelected,
                      child: widget.absorb
                          // The opaque detector below covers the asset's whole
                          // rectangle, which is right until an asset's box is
                          // mostly empty. A run's is: it spans the two devices
                          // it plugs into, so without the shape gate the cable
                          // eats every editor tap meant for the equipment it
                          // passes.
                          ? ShapedHitRegion(
                              test: (local) => asset.hitTestBox(
                                  local,
                                  Size(assetW, assetH),
                                  widget.assets,
                                  Size(W, H)),
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: widget.onTap != null
                                    ? () => widget.onTap!(asset)
                                    : null,
                                onDoubleTap: widget.onDoubleTap != null
                                    ? () => widget.onDoubleTap!(asset)
                                    : null,
                                onPanUpdate: widget.onPanUpdate != null
                                    ? (d) => widget.onPanUpdate!(asset, d)
                                    : null,
                                onPanStart: widget.onPanStart != null
                                    ? (details) =>
                                        widget.onPanStart!(asset, details)
                                    : null,
                                // The host's menu wins when supplied: it
                                // carries editing actions that must be
                                // reachable whether or not MCP chat is
                                // available, and folds the AI entries in
                                // itself.
                                onSecondaryTapUp: widget.onSecondaryTap != null
                                    ? (details) => widget.onSecondaryTap!(
                                          asset,
                                          details.globalPosition,
                                        )
                                    : kChatEnabled
                                        ? (details) {
                                            showEditorAssetContextMenu(
                                              context,
                                              ref,
                                              details.globalPosition,
                                              asset,
                                            );
                                          }
                                        : null,
                              ))
                          : GestureDetector(
                              // Runtime view: only secondary tap is
                              // handled here (chat context menu). Primary
                              // taps must pass through to the asset's
                              // own GestureDetectors. translucent keeps
                              // us from swallowing them.
                              behavior: HitTestBehavior.translucent,
                              onSecondaryTapUp:
                                  kChatEnabled
                                      ? (details) {
                                          showAssetContextMenu(
                                            context,
                                            details.globalPosition,
                                            () => debugAsset(ref, asset),
                                          );
                                        }
                                      : null,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          );

          // Proposal visual indicators: dashed border + AI badge
          if (isProposed) {
            positionedChildren.add(
              Positioned(
                // Sized to the rotated AABB, like the asset's own Positioned.
                // _rotatedAssetFrame uses an OverflowBox, which needs bounded
                // constraints to size against -- on a left/top-only Positioned
                // it receives unbounded ones and paints nothing.
                left: cx - halfAabbW,
                top: cy - halfAabbH,
                width: aabbW,
                height: aabbH,
                child: IgnorePointer(
                  // Rotate with the asset, exactly as the blue selection
                  // border does (see the layering note above). Drawn
                  // unrotated, the dashed box sat askew across a turned
                  // conveyor and read as marking the wrong thing.
                  child: _rotatedAssetFrame(
                    angle: angleRadians,
                    width: assetW,
                    height: assetH,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        CustomPaint(
                          size: Size(assetW, assetH),
                          painter: DashedBorderPainter(color: Colors.amber),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          // The frame turns with the asset; the badge is a
                          // label and stays upright so it is still readable
                          // on a rotated or upside-down asset.
                          child: Transform.rotate(
                            angle: -angleRadians,
                            alignment: Alignment.center,
                            child: const ProposalBadge(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          // B) add the label (if any)
          if (paintsLabel) {
            var pos = asset.textPos ?? TextPos.right;
            if (xMirror && (pos == TextPos.left || pos == TextPos.right)) {
              pos = pos == TextPos.left ? TextPos.right : TextPos.left;
            }
            if (yMirror && (pos == TextPos.above || pos == TextPos.below)) {
              pos = pos == TextPos.above ? TextPos.below : TextPos.above;
            }
            final labelOff = labelOffset(center, assetSize, textSize, pos);
            // The label `Positioned` is added AFTER the asset visual in
            // `positionedChildren`, so it paints (and hit-tests) on TOP
            // of the asset. If the label is allowed to consume primary
            // pointer events, it eats taps that should reach the asset's
            // own GestureDetectors / InkWell underneath — most visibly
            // for a Button with `TextPos.inside`.
            //
            // In editor mode (`absorb=true`) we wrap the label in
            // `IgnorePointer` so the editor's overlay GestureDetector
            // sitting beneath gets every event (drag / select / context
            // menu) — otherwise an asset whose label overlaps its body
            // can't be moved.
            //
            // In runtime mode (`absorb=false`) we keep the secondary-tap
            // (right-click → AI context menu) binding so operators can
            // open the AI menu by right-clicking the label, but we wrap
            // the underlying Text in `IgnorePointer` so it does not
            // hit-test for primary taps. Combined with
            // `HitTestBehavior.translucent` on the wrapping
            // GestureDetector, primary taps on the label fall through to
            // the asset body below (Stack hit-testing visits earlier
            // children when a translucent detector reports a hit but has
            // no matching gesture handler).
            final labelWidget = widget.absorb
                ? IgnorePointer(child: Text(asset.text!, style: labelStyle))
                : GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapUp: kChatEnabled
                        ? (details) {
                            showAssetContextMenu(
                              context,
                              details.globalPosition,
                              () => debugAsset(ref, asset),
                            );
                          }
                        : null,
                    child: IgnorePointer(
                      child: Text(asset.text!, style: labelStyle),
                    ),
                  );
            positionedChildren.add(
              Positioned(
                left: labelOff.dx,
                top: labelOff.dy,
                child: labelWidget,
              ),
            );
          }

          // C) add the red center dot
          // positionedChildren.add(
          //   Positioned(
          //     left: cx - 4,
          //     top: cy - 4,
          //     child: Container(
          //       width: 8,
          //       height: 8,
          //       decoration: BoxDecoration(
          //         color: Colors.red,
          //         shape: BoxShape.circle,
          //       ),
          //     ),
          //   ),
          // );
        }

        // One mark, added last so it draws over the assets and their labels
        // — only one pane is open at a time, and a mark per asset would put
        // an animated overlay on every device on the page.
        positionedChildren.add(
          _OpenPaneMark(frames: frames, hitShapeOf: _hitShapeOf),
        );

        // The scope carries the *effective* flags, so assets that paint
        // their own text can counter-mirror it (see AssetMirrorScope).
        //
        // PageAssetsScope sits inside it and carries the page itself, for the
        // one asset whose appearance depends on the others: a cable has to
        // find the devices its ends belong to, and `build(BuildContext)` is
        // the only thing it is handed.
        return AssetMirrorScope(
          xMirror: xMirror,
          yMirror: yMirror,
          child: PageAssetsScope(
            assets: widget.assets,
            canvas: Size(W, H),
            child: Stack(
              fit: StackFit.expand,
              children: positionedChildren,
            ),
          ),
        );
      },
    );
  }
}

/// Where one asset ended up on the canvas, in canvas pixels.
///
/// [size] is the asset's own, unrotated box — what the asset paints into and
/// what the editor's selection border is drawn around — while [aabb] is the
/// axis-aligned box that box needs once it is turned by [angle].
@immutable
class _AssetFrame {
  final Offset center;
  final Size size;
  final Size aabb;
  final double angle;

  const _AssetFrame({
    required this.center,
    required this.size,
    required this.aabb,
    required this.angle,
  });

  // By value: the stack builds a fresh frame on every rebuild, and the mark
  // re-probes the asset's hit test whenever the frame it is drawn from
  // changes. Identity would make that every rebuild.
  @override
  bool operator ==(Object other) =>
      other is _AssetFrame &&
      other.center == center &&
      other.size == size &&
      other.aabb == aabb &&
      other.angle == angle;

  @override
  int get hashCode => Object.hash(center, size, aabb, angle);
}

/// Marks the asset the open side pane belongs to.
///
/// A pane is a strip against the right edge, well away from the machine it is
/// about, and on a mimic with four identical conveyors in a row the header
/// alone does not settle which one an operator is jogging. So while a pane is
/// open, its asset is outlined.
///
/// The outline is the asset's own, where it has one. A conveyor turn is an
/// arc across a box it barely fills and `ConveyorPainter.hitTest` claims only
/// the painted belt, so a rectangle would mark a great deal of page the
/// operator cannot touch; the belt publishes the very path its hit test
/// answers from ([AssetHitShape]) and that is what gets drawn. The mark and
/// the tap target are then the same object, not two descriptions of it.
///
/// Assets that publish nothing take taps on their whole face, and their face
/// is what gets marked. `hit_boundary_drift_test` holds both kinds against
/// the hit test they actually have, so a published shape cannot quietly stop
/// being true.
///
/// Deliberately quiet: a fine line in the same ink the labels use, fading in,
/// standing just off the asset and never filling it. Equipment state on this
/// page is carried by what an asset is filled with ([HmiStateColors]) — a
/// mark that tinted the asset would read as one more state, which is the one
/// thing it must not do.
class _OpenPaneMark extends StatefulWidget {
  /// Every asset on the canvas, by identity — the pane names its asset, not
  /// its position, so the geometry is looked up here.
  final Map<Object, _AssetFrame> frames;

  /// The shape an asset publishes for what it takes taps on, or null when it
  /// publishes none.
  final ({Path path, RenderBox box})? Function(Object asset) hitShapeOf;

  const _OpenPaneMark({required this.frames, required this.hitShapeOf});

  @override
  State<_OpenPaneMark> createState() => _OpenPaneMarkState();
}

class _OpenPaneMarkState extends State<_OpenPaneMark>
    with SingleTickerProviderStateMixin {
  /// How far off the asset the outline stands. A property of the style now —
  /// how much air the ring is given is half of whether it reads as a mark
  /// around the machine rather than a border the machine has grown.
  static double get _standoff => HitBoundaryStyle.selection.standoff;

  /// Drives the crawl. Repeating, so it is only ever allowed to run while
  /// there is actually a ring on screen — a ticker that never stops is a
  /// frame scheduled forever on a mimic that is otherwise idle, and it leaves
  /// every `pumpAndSettle` in reach of this widget waiting on it.
  ///
  /// Built in `initState` rather than lazily: a page where no pane is ever
  /// opened never reads it, and a `late final` initialiser first run from
  /// `dispose` asks for a `TickerMode` that is no longer there to ask.
  late final AnimationController _march;

  /// The asset being marked, and where it sits. Both kept after the pane
  /// closes so the mark has something to fade OUT of — dropping them would
  /// snap it away while the pane it belongs to is still gliding off screen.
  Object? _target;
  _AssetFrame? _frame;
  bool _shown = false;

  /// The outline, in this widget's coordinates — which are the canvas's,
  /// since the mark fills the stack.
  ///
  /// Null means there is no published shape to draw: either it has not been
  /// looked for yet ([_answered] false), or it has and the asset publishes
  /// none ([_answered] true), in which case its face is drawn instead.
  List<List<Offset>>? _outline;
  bool _answered = false;
  bool _lookupScheduled = false;

  @override
  void initState() {
    super.initState();
    _march = AnimationController(
      vsync: this,
      duration: HitBoundaryStyle.selection.period,
    );
    SidePaneHost.subject.addListener(_onSubjectChanged);
    _sync(notify: false);
  }

  @override
  void didUpdateWidget(_OpenPaneMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A rebuild is already under way (the canvas resized, an asset moved), so
    // take the new geometry without asking for another one.
    _sync(notify: false);
  }

  @override
  void dispose() {
    SidePaneHost.subject.removeListener(_onSubjectChanged);
    _march.dispose();
    super.dispose();
  }

  /// Runs the crawl only while a traced ring is showing.
  void _driveMarch() {
    final wanted = _shown && _answered;
    if (wanted == _march.isAnimating) return;
    if (wanted) {
      _march.repeat();
    } else {
      // Stopped and rewound rather than just stopped: the ring fades out over
      // 180ms and comes back somewhere else entirely, so where the dashes had
      // got to on the last asset means nothing on the next one.
      _march.stop();
      _march.value = 0;
    }
  }

  void _onSubjectChanged() {
    if (mounted) _sync();
  }

  void _sync({bool notify = true}) {
    final subject = SidePaneHost.subject.value;
    // An unknown subject — the page editor's config pane, the database stats
    // pane, anything opened from outside an asset — leaves the page unmarked.
    final live = subject == null ? null : widget.frames[subject];
    final shown = live != null;
    // By value, not identity: every rebuild mints a new frame, and only a
    // frame that says something different is worth re-tracing for.
    final moved = shown && (!identical(subject, _target) || live != _frame);
    if (shown == _shown && !moved) {
      if (!shown) _follow(notify: notify);
      return;
    }

    void apply() {
      _shown = shown;
      if (live != null) {
        _target = subject;
        _frame = live;
      }
      if (moved) {
        _outline = null;
        _answered = false;
      }
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
    _driveMarch();
    if (shown && !_answered) _scheduleLookup();
  }

  /// Keeps a fading ring on its asset.
  ///
  /// The subject is cleared the moment a close begins, but the canvas can
  /// still move under the ring while it fades out: closing a pane the page
  /// had stepped aside for releases the inset strip, and [SidePaneInset]
  /// re-lays the page out at full width in that same frame. The cached
  /// outline is in the old layout's coordinates, so left alone it spends the
  /// fade ghosting off to the side of where the asset now is. The relayout
  /// only rescales canvas coordinates, so the outline is carried onto the
  /// asset's new frame by scaling it between the two — synchronously, not by
  /// a post-frame probe, so no frame is ever painted in the wrong place.
  void _follow({required bool notify}) {
    final target = _target;
    final from = _frame;
    if (target == null || from == null) return;
    final to = widget.frames[target];
    if (to == from) return;

    void apply() {
      // Nothing to carry the ring onto — the asset left the page, or turned,
      // so the old contour is no shape for the new frame. For the tail of a
      // fade, no ring beats a wrong one.
      if (to == null ||
          to.angle != from.angle ||
          from.size.width <= 0 ||
          from.size.height <= 0) {
        _target = null;
        _frame = null;
        _outline = null;
        _answered = false;
        return;
      }
      final sx = to.size.width / from.size.width;
      final sy = to.size.height / from.size.height;
      final outline = _outline;
      _frame = to;
      if (outline == null) return;
      _outline = [
        for (final ring in outline)
          [
            for (final p in ring)
              to.center +
                  Offset(
                    (p.dx - from.center.dx) * sx,
                    (p.dy - from.center.dy) * sy,
                  ),
          ],
      ];
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  /// Looks the asset's shape up after the frame it was laid out in.
  ///
  /// Post-frame because the asset may have only just been built — a pane
  /// opened from a tap on an asset that moved in the same frame, say — and a
  /// widget that is not laid out has no box to map its shape out of.
  void _scheduleLookup() {
    if (_lookupScheduled) return;
    _lookupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lookupScheduled = false;
      if (mounted) _lookUp();
    });
  }

  void _lookUp() {
    final target = _target;
    final frame = _frame;
    if (target == null || frame == null || !_shown) return;

    final outline = _outlineFor(target, frame);
    if (_answered && outline == _outline) return;
    setState(() {
      _outline = outline;
      _answered = true;
    });
    _driveMarch();
  }

  /// What to outline, in canvas coordinates, stood off from the asset.
  ///
  /// The asset's published shape where it has one, and its face where it does
  /// not — an asset that takes taps on an opaque box is honestly a box. Null
  /// only while there is nothing laid out to measure against.
  List<List<Offset>>? _outlineFor(Object target, _AssetFrame frame) {
    final self = context.findRenderObject();
    if (self is! RenderBox || !self.attached || !self.hasSize) return null;

    final shape = widget.hitShapeOf(target);
    // Into the canvas's coordinates first, so the standoff is a distance on
    // screen rather than one in the asset's own scale — and so the rotation
    // and mirroring the asset already went through come along rather than
    // being re-derived here.
    final path = shape != null
        ? shape.path.transform(shape.box.getTransformTo(self).storage)
        : _facePath(frame);

    return [
      for (final ring in flattenPath(path))
        offsetContour(ring, _standoff, inside: path.contains),
    ];
  }

  /// The asset's own rectangle, turned with it — the shape of an asset that
  /// answers a pointer anywhere on its face.
  ///
  /// Corners rounded by a hair. Square ones read as a crop mark over a plant
  /// view; the editor's selection border is deliberately hard-edged because
  /// it is about the box, and this is about the machine.
  Path _facePath(_AssetFrame frame) {
    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: frame.size.width,
      height: frame.size.height,
    );
    final corner = math.min(6.0, rect.shortestSide / 4);
    final turned = Matrix4.identity()
      ..translateByDouble(frame.center.dx, frame.center.dy, 0, 1)
      ..rotateZ(frame.angle);
    // `transform` returns a new path rather than turning this one, so it
    // cannot be the last step of a cascade — the cascade would hand back the
    // untransformed path, and the mark would be drawn at the canvas origin.
    final face = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(corner)));
    return face.transform(turned.storage);
  }

  /// The dashes' colour, resolved here because a painter has no context.
  ///
  /// Off the page's brightness rather than fixed: one ink cannot serve both
  /// schemes. The dark tone is 14.5:1 against the muted light page and 1.1:1
  /// against the dark one, and a ring in the wrong one of them is not a quiet
  /// mark but an invisible one.
  ///
  /// A scheme role, where the style names one, wins over both — it is a
  /// deliberate colour and the theme resolves it per scheme anyway. It comes
  /// back fully opaque, so it is knocked down to the ink's own alpha and sits
  /// on the page with the same weight the neutral tones do.
  Color _ink(BuildContext context) {
    final role = HitBoundaryStyle.selection.inkRole;
    if (role != null) {
      return role
          .resolve(context)
          .withValues(alpha: HitBoundaryPainter.inkOpacity);
    }
    return HitBoundaryPainter.inkFor(Theme.of(context).brightness);
  }

  /// The tone the gaps carry when the style asks for two of them — always the
  /// opposite of [_ink], so the pair keeps its full luminance spread.
  Color _halo(BuildContext context) =>
      HitBoundaryPainter.haloFor(Theme.of(context).brightness);

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    // Nothing has been marked on this page yet: no outline, and no box in the
    // stack that could take a tap meant for an asset.
    if (frame == null) return const SizedBox.shrink();

    final outline = _outline;

    return Positioned.fill(
      // Filling the stack rather than the asset: the outline is traced in the
      // asset's coordinates and mapped into the canvas's, so it is painted in
      // the canvas's too — no second copy of the rotation and mirroring the
      // asset already went through.
      child: IgnorePointer(
        child: AnimatedOpacity(
          // Held at nothing until the probe answers, so the fallback never
          // flashes up in the frame before the traced outline replaces it.
          opacity: _shown && _answered ? 1 : 0,
          // Just under the pane's own 220ms glide: the mark should be there
          // by the time the operator's eye arrives at the pane, and gone
          // before the pane has finished leaving.
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: AnimatedBuilder(
            animation: _march,
            builder: (context, _) => CustomPaint(
              key: openPaneMarkKey,
              painter: HitBoundaryPainter(
                contours: outline ?? const [],
                phase: _march.value,
                ink: _ink(context),
                halo: _halo(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Marks the outline drawn around the asset whose side pane is open. At most
/// one per page, and only while a pane opened from an asset is showing.
const Key openPaneMarkKey = ValueKey('open-pane-mark');

class AssetView extends StatelessWidget {
  final String pageName;
  const AssetView({Key? key, required this.pageName}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return BaseScaffold(
      title: 'Asset View',
      body: PlantPageView(pageName: pageName),
    );
  }
}

/// The plant page itself: the canvas, its assets, and — while the database has
/// not confirmed the layout — a mark saying so.
///
/// Split out of [AssetView] so it can be tested without the app shell.
class PlantPageView extends ConsumerStatefulWidget {
  final String pageName;
  const PlantPageView({Key? key, required this.pageName}) : super(key: key);

  /// Identifies the "not confirmed with the server yet" strip.
  static const Key unverifiedBannerKey = Key('unverified-page-banner');

  @override
  ConsumerState<PlantPageView> createState() => _PlantPageViewState();
}

class _PlantPageViewState extends ConsumerState<PlantPageView> {
  // Memo for [_confirmedPage], keyed on the identity of the two inputs. The
  // comparison serializes the page, so it must happen once per new pair of
  // copies — not once per build.
  AssetPage? _lastFromDatabase;
  AssetPage? _lastCached;
  AssetPage? _reconciled;

  /// The instance to render once the database has confirmed [dbPage].
  ///
  /// `AssetStack` keys every asset by `ObjectKey(asset)` — object identity —
  /// so that reordering moves elements instead of restarting each asset's
  /// subscriptions (#180). The database copy is deserialized separately from
  /// the cached one, so *every* `Asset` in it is a different instance even
  /// when the layout is byte-for-byte the same. Handing it straight to
  /// `AssetStack` would therefore tear the whole page down and rebuild it the
  /// moment Postgres answers: every subscription restarts, every asset flashes
  /// back through its loading state, and any equipment pane the operator has
  /// opened closes under their finger (pane-owning assets close their pane
  /// from `dispose` — see `SidePaneOwner`).
  ///
  /// So when the server confirms exactly what was already on screen, keep the
  /// instance that is already mounted. When the layout genuinely differs the
  /// database copy is used and the teardown is correct — that is the same
  /// rebuild the app already does after every page-editor save.
  AssetPage? _confirmedPage(AssetPage? dbPage, AssetPage? cachedPage) {
    if (dbPage == null || cachedPage == null) return dbPage;
    if (identical(dbPage, _lastFromDatabase) &&
        identical(cachedPage, _lastCached)) {
      return _reconciled;
    }
    _lastFromDatabase = dbPage;
    _lastCached = cachedPage;
    final same = jsonEncode(dbPage.toJson()) == jsonEncode(cachedPage.toJson());
    return _reconciled = same ? cachedPage : dbPage;
  }

  String get pageName => widget.pageName;

  @override
  Widget build(BuildContext context) {
    // `pageManagerProvider` is the authority and it wins the moment it
    // answers: riverpod rebuilds this widget with the database copy, which is
    // used from then on — including across later refreshes, because
    // `valueOrNull` keeps the last resolved value. The cached copy is only
    // ever read while there is no database copy at all, so there is no path
    // by which a stale page outlives the fresh one.
    //
    // What that does not cover is a database that never answers. Then the
    // cached page stays on screen indefinitely, which is the right call — a
    // blank page tells the operator nothing, and the live values on the page
    // come from OPC UA, not from here. But the layout itself could be out of
    // date: an asset moved, deleted, or re-pointed at a different tag on
    // another station. So it is rendered under a standing mark for as long as
    // it is unconfirmed, in the theme's "unreadable state" violet. The mark
    // clears by itself the instant the database copy lands.
    final fromDatabase = ref.watch(pageManagerProvider).valueOrNull;
    final pageManager = fromDatabase ?? ref.watch(bootstrapPageManagerProvider);
    final unverified = fromDatabase == null && pageManager != null;

    if (pageManager == null) {
      // Nothing cached and nothing loaded — as blank as it ever was.
      return const SizedBox.shrink();
    }

    // When the database confirms the layout that is already mounted, keep the
    // mounted instance rather than swapping in an identical-but-new one.
    final page = unverified
        ? pageManager.pages[pageName]
        : _confirmedPage(
            pageManager.pages[pageName],
            ref.read(bootstrapPageManagerProvider)?.pages[pageName],
          );

    final Widget content;
    if (page == null) {
      content = Center(
        child: Text(unverified
            // A page created on another station is simply absent from this
            // station's cache. Saying "not found" would be a guess.
            ? 'Waiting for the server to send the plant pages…'
            : 'Page: "$pageName" not found'),
      );
    } else {
      // An equipment pane (a tapped conveyor, a sensor) docks over the right
      // edge; when it would cover the very device the operator tapped — and
      // only then — the inset re-fits the plant view beside it. Assets open
      // their pane from their own build context, which is how `showSidePane`
      // knows where the tapped device is.
      content = SidePaneInset(
        child: ZoomableCanvas(
          interactive: !page.zoomPanDisabled,
          child: LayoutBuilder(
            // A tap on empty page -- nothing under it that takes taps --
            // closes an open pane. Translucent so every asset still sees
            // the tap first: an asset's own GestureDetector sits deeper in
            // the tree and wins the arena, and this one only fires when
            // no asset claimed it. Inside the ZoomableCanvas on purpose:
            // outside it, the canvas's scale recognizer would take the
            // sweep for a plain tap and this would never fire.
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => closeSidePane(),
              child: AssetStack(
                assets: page.assets,
                constraints: constraints,
                absorb: false,
                selectedAssets: const {},
                mirroringDisabled: page.mirroringDisabled,
              ),
            ),
          ),
        ),
      );
    }

    // The Column is here whether or not the strip is, and the strip's slot is
    // always child 0. Collapsing to a bare `content` when the mark clears
    // would change the depth of everything below it, and Flutter reconciles
    // by position — so the whole plant page would be torn down and every
    // asset re-subscribed purely because a banner went away. Keeping the
    // shape fixed means the mark appearing or clearing costs one zero-height
    // box, and nothing under it is disturbed.
    //
    // The strip sits outside the canvas on purpose: inside it, it would zoom
    // and pan away with the plant.
    return Column(
      children: [
        if (unverified)
          const _UnverifiedPageBanner()
        else
          const SizedBox.shrink(),
        Expanded(child: content),
      ],
    );
  }
}

/// Says that what is on screen is the last layout this station saw, not one
/// the server has confirmed.
class _UnverifiedPageBanner extends StatelessWidget {
  const _UnverifiedPageBanner();

  @override
  Widget build(BuildContext context) {
    final colors = HmiStateColors.of(context);
    return Container(
      key: PlantPageView.unverifiedBannerKey,
      width: double.infinity,
      color: colors.violet,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 16, color: colors.onState),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Last known layout — the server has not confirmed it. '
              'Assets may have moved or changed since.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onState),
            ),
          ),
        ],
      ),
    );
  }
}

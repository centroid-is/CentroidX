// The plant view marks the asset whose side pane is open.
//
// A pane is a strip against the right edge of a screen full of machinery. On
// a mimic with four identical conveyors in a row, the pane's header does not
// settle WHICH of them an operator is about to jog — so the asset the pane
// was opened from is outlined for as long as the pane is up.
//
// Nothing about this is per-asset: an asset opens its pane from its own build
// context (it already has to, for `showSidePane`'s `avoidRect`), and the
// `SidePaneSubject` that `AssetStack` puts around every asset is what turns
// that context into "this pane is about that asset".
//
// Contract under test:
//   - a pane opened from inside an asset marks that asset, and only it;
//   - an asset that publishes the shape it takes taps on is marked with that
//     shape, not with its box;
//   - the mark follows a swap to another asset's pane;
//   - closing the pane takes the mark with it;
//   - a pane opened from outside any asset (the page editor's config pane,
//     the database stats pane) marks nothing;
//   - the mark never takes a tap meant for the asset underneath it.
//
// The ring's dashes crawl while it is up, so nothing here settles once a pane
// is open — see `pumpMarked`. What the crawl itself does is
// `hit_boundary_test`'s business; this file is about which asset is ringed.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/hit_boundary.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    // The host is static; a pane left open leaks into the next test.
    closeSidePane(immediate: true);
  });

  /// How visible the mark is. The mark stays in the tree at zero opacity once
  /// it has been used — so that it has something to fade out of — which makes
  /// opacity, not presence, the question of whether it is on screen.
  double markOpacity(WidgetTester tester) {
    final finder = find.byKey(openPaneMarkKey);
    if (finder.evaluate().isEmpty) return 0;
    // `.first` — the nearest one out. The route's own transition is a
    // FadeTransition too, and it is further up the same path.
    return tester
        .widget<FadeTransition>(
          find
              .ancestor(of: finder, matching: find.byType(FadeTransition))
              .first,
        )
        .opacity
        .value;
  }

  /// The traced outline, in screen coordinates — one list of points per ring.
  ///
  /// Read off the painter rather than off the widget's box: the mark fills
  /// the canvas and paints into it, so its render box says nothing about
  /// which asset is marked.
  List<List<Offset>> markOutline(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byKey(openPaneMarkKey));
    final painter = paint.painter;
    expect(painter, isA<HitBoundaryPainter>());
    final origin = tester.getTopLeft(find.byKey(openPaneMarkKey));
    return [
      for (final ring in (painter as HitBoundaryPainter).contours)
        [for (final point in ring) point + origin],
    ];
  }

  /// What the outline encloses, in screen coordinates.
  Rect markBounds(WidgetTester tester) {
    var rect = Rect.fromLTRB(double.infinity, double.infinity,
        double.negativeInfinity, double.negativeInfinity);
    for (final ring in markOutline(tester)) {
      for (final p in ring) {
        rect = Rect.fromLTRB(
          math.min(rect.left, p.dx),
          math.min(rect.top, p.dy),
          math.max(rect.right, p.dx),
          math.max(rect.bottom, p.dy),
        );
      }
    }
    return rect;
  }

  Offset markCentre(WidgetTester tester) => markBounds(tester).center;

  /// Settles everything about an open pane that can be settled.
  ///
  /// Not `pumpAndSettle`: the ring's dashes crawl for as long as it is up, so
  /// there is no settled state to wait for and settling would sit there until
  /// it timed out. These are the three waits that actually matter — a frame
  /// for the pane's own build, one past the post-frame trace of the asset's
  /// hit test, and one long enough to clear the mark's 180ms fade.
  Future<void> pumpMarked(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a pane opened from an asset marks that asset', (tester) async {
    // Both well clear of the right edge: the pane docks over it, and a tap
    // meant for the second asset would land on the pane instead.
    final left = _PaneAsset('left', x: 0.15);
    final right = _PaneAsset('right', x: 0.35);
    await tester.pumpWidget(_wrap([left, right]));
    await tester.pumpAndSettle();

    expect(markOpacity(tester), 0, reason: 'nothing is open yet');

    await tester.tap(find.text('left'));
    await pumpMarked(tester);

    expect(isSidePaneOpen(id: 'pane:left'), isTrue);
    expect(markOpacity(tester), 1);

    // This asset takes taps across its whole box, so the outline is that box
    // — standing just off it, not drawn on it.
    final box = tester.getRect(find.byKey(const ValueKey('face:left')));
    final outline = markBounds(tester);
    expect(outline.center.dx, closeTo(box.center.dx, 2),
        reason: 'the mark belongs to the asset the pane was opened from');
    final air = HitBoundaryStyle.selection.standoff * 2;
    expect(outline.width, greaterThan(box.width));
    expect(outline.width, lessThan(box.width + air + 4));
    expect(outline.height, greaterThan(box.height));
    expect(outline.height, lessThan(box.height + air + 4));

    // A second asset: the pane swaps, and so does the ring.
    await tester.tap(find.text('right'));
    await pumpMarked(tester);

    expect(markOpacity(tester), 1);
    expect(
      markCentre(tester).dx,
      closeTo(tester.getCenter(find.text('right')).dx, 2),
    );
    expect(find.byKey(openPaneMarkKey), findsOneWidget,
        reason: 'one pane is open, so exactly one asset is marked');
  });

  testWidgets('a published shape is what gets marked, not the box',
      (tester) async {
    // The conveyor case in miniature. A turned belt is an arc across a box it
    // barely fills and `ConveyorPainter.hitTest` claims only the painted
    // belt, so a mark drawn as the box would frame a great deal of page that
    // ignores taps. Here the asset takes taps on a disc inside a rectangle
    // and publishes that disc: the mark has to come back a disc.
    final asset = _DiscAsset(radius: 40);
    await tester.pumpWidget(_wrap([asset]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(discKey));
    await pumpMarked(tester);
    expect(asset.taps, 1, reason: 'the tap landed inside the disc');

    final bounds = markBounds(tester);
    final centre = bounds.center;
    for (final ring in markOutline(tester)) {
      for (final point in ring) {
        // Every point sits on the rim of the disc, standing off it evenly —
        // nothing out at the corners of the box. Off the style's standoff
        // rather than a number, so tuning how much air the ring is given does
        // not have to be re-typed here.
        expect((point - centre).distance,
            closeTo(40 + HitBoundaryStyle.selection.standoff, 1.5));
      }
    }

    final box = tester.getRect(find.byType(AssetStack));
    expect(bounds.width, lessThan(box.width * 0.2 + 24),
        reason: 'the outline is the disc, not the asset rectangle');
  });

  testWidgets('a pane opened from a rack slice marks that slice alone',
      (tester) async {
    // The Beckhoff case in miniature: a rack head draws its slices inside
    // its own box, so a tap on one slice used to inherit the rack's subject
    // and the ring framed the whole block. Each slice sits in its own
    // [SubdeviceSubject] and is registered under the rack's frame via
    // [Asset.childAssets]; the ring must come back that one slice's rect.
    final rack = _RackAsset();
    await tester.pumpWidget(_wrap([rack]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('sliceA'));
    await pumpMarked(tester);

    expect(isSidePaneOpen(id: 'pane:sliceA'), isTrue);
    expect(markOpacity(tester), 1);

    final slice = tester.getRect(find.byKey(const ValueKey('face:sliceA')));
    final rackBox = tester.getRect(find.byKey(rackRowKey));
    final bounds = markBounds(tester);
    final air = HitBoundaryStyle.selection.standoff * 2;
    expect(bounds.center.dx, closeTo(slice.center.dx, 2),
        reason: 'the ring belongs to the tapped slice');
    expect(bounds.width, lessThan(slice.width + air + 4),
        reason: 'the ring is the slice, not the whole rack');
    expect(bounds.width, lessThan(rackBox.width * 0.75));
    expect(bounds.height, closeTo(slice.height + air, 4));

    // The neighbouring slice: the pane swaps and the ring crosses the rack.
    await tester.tap(find.text('sliceB'));
    await pumpMarked(tester);

    final sliceB = tester.getRect(find.byKey(const ValueKey('face:sliceB')));
    expect(markCentre(tester).dx, closeTo(sliceB.center.dx, 2));
    expect(find.byKey(openPaneMarkKey), findsOneWidget);
  });

  testWidgets('an asset that publishes nothing is marked with its face',
      (tester) async {
    // Most assets take taps on an opaque box, and for them the box is not a
    // second opinion — it is the answer.
    await tester.pumpWidget(_wrap([_PaneAsset('one', x: 0.5)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('one'));
    await pumpMarked(tester);

    expect(markOpacity(tester), 1);
    // Its face, stood off from it — four corners, near enough square.
    final face = tester.getRect(find.byKey(const ValueKey('face:one')));
    final bounds = markBounds(tester);
    expect(bounds.center.dx, closeTo(face.center.dx, 1));
    expect(bounds.center.dy, closeTo(face.center.dy, 1));
    final air = HitBoundaryStyle.selection.standoff * 2;
    expect(bounds.width, closeTo(face.width + air, 2));
    expect(bounds.height, closeTo(face.height + air, 2));
  });

  testWidgets('closing the pane clears the mark', (tester) async {
    await tester.pumpWidget(_wrap([_PaneAsset('one', x: 0.5)]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('one'));
    await pumpMarked(tester);
    expect(markOpacity(tester), 1);

    closeSidePane();
    await tester.pumpAndSettle();

    expect(isSidePaneOpen(), isFalse);
    expect(markOpacity(tester), 0);
  });

  testWidgets('a fading ring follows the asset through a relayout',
      (tester) async {
    // The ghosting case. Closing a pane the page had stepped aside for
    // releases the inset strip, and the page is re-laid-out at full width in
    // the same frame — while the ring, whose subject is already gone, spends
    // 180ms fading out. An outline cached in the old layout's coordinates
    // would sit off to the side of the asset for the whole fade. It has to be
    // carried onto the asset's new frame instead, in the frame of the
    // relayout itself.
    final asset = _PaneAsset('one', x: 0.5);
    await tester.pumpWidget(_wrap([asset]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('one'));
    await pumpMarked(tester);
    expect(markOpacity(tester), 1);

    closeSidePane();
    // A slice of the fade, not all of it: the ring must still be up when the
    // canvas moves under it. One pump for the fade to be asked for, one to
    // get 50ms into it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(markOpacity(tester), greaterThan(0));
    expect(markOpacity(tester), lessThan(1));

    // The relayout the inset release causes, reproduced directly: the canvas
    // changes size mid-fade and every asset lands somewhere new.
    await tester.pumpWidget(_wrap([asset], size: const Size(600, 450)));
    await tester.pump(const Duration(milliseconds: 16));

    expect(markOpacity(tester), greaterThan(0),
        reason: 'still mid-fade — this is the window the ghost showed in');
    final face = tester.getRect(find.byKey(const ValueKey('face:one')));
    final bounds = markBounds(tester);
    expect(bounds.center.dx, closeTo(face.center.dx, 1),
        reason: 'the fading ring stays on the asset, not on the old layout');
    expect(bounds.center.dy, closeTo(face.center.dy, 1));
    // The carried ring scales as one piece, standoff included, so its air is
    // three quarters of the styled one here — close enough for the tail of a
    // fade, and the bound below allows exactly that much slack.
    final air = HitBoundaryStyle.selection.standoff * 2;
    expect(bounds.width, greaterThan(face.width));
    expect(bounds.width, lessThan(face.width + air + 2));
    expect(bounds.height, greaterThan(face.height));
    expect(bounds.height, lessThan(face.height + air + 2));
  });

  testWidgets('an asset deleted mid-fade takes its ring with it',
      (tester) async {
    // The frame the ring would be carried onto is gone; a ring scaled onto
    // nothing would hang in empty page. It goes at once instead.
    final asset = _PaneAsset('one', x: 0.5);
    await tester.pumpWidget(_wrap([asset]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('one'));
    await pumpMarked(tester);

    closeSidePane();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(markOpacity(tester), greaterThan(0));

    await tester.pumpWidget(_wrap([]));
    await tester.pump(const Duration(milliseconds: 16));

    expect(markOpacity(tester), 0);
  });

  testWidgets('a pane opened from outside an asset marks nothing',
      (tester) async {
    // What the page editor does: it opens its config pane from the page's own
    // context, not the asset's, and marks the asset itself with the editor's
    // selection border. Same for panes that are about no asset at all.
    late BuildContext pageContext;
    await tester.pumpWidget(_wrap(
      [_PaneAsset('one', x: 0.5)],
      onPageContext: (c) => pageContext = c,
    ));
    await tester.pumpAndSettle();

    showSidePane(
      context: pageContext,
      id: 'not-an-asset',
      builder: (_) => const Text('stats'),
    );
    await tester.pumpAndSettle();

    expect(isSidePaneOpen(id: 'not-an-asset'), isTrue);
    expect(markOpacity(tester), 0);
  });

  testWidgets('the mark does not swallow taps on its asset', (tester) async {
    // The ring is drawn over the asset it is around, and the plant view is
    // live underneath a pane: a start button that stopped taking taps the
    // moment its pane opened would be worse than no mark at all.
    final asset = _PaneAsset('one', x: 0.5);
    await tester.pumpWidget(_wrap([asset]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('one'));
    await pumpMarked(tester);
    expect(asset.taps, 1);
    expect(markOpacity(tester), 1);

    // Straight through the middle of the ring, into the asset.
    await tester.tapAt(markCentre(tester));
    await pumpMarked(tester);
    expect(asset.taps, 2);
  });
}

Widget _wrap(
  List<Asset> assets, {
  ValueChanged<BuildContext>? onPageContext,
  Size size = const Size(800, 600),
}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
      body: Builder(builder: (context) {
        onPageContext?.call(context);
        return SizedBox(
          width: size.width,
          height: size.height,
          child: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: assets,
              constraints: constraints,
              selectedAssets: const {},
              mirroringDisabled: true,
              // Runtime mode: assets take their own taps and open their own
              // panes, which is the only path the mark is about.
              absorb: false,
            ),
          ),
        );
      }),
      ),
    ),
  );
}

/// An asset that takes taps on a disc and ignores the rest of its box, the
/// way a conveyor takes them on the painted belt alone.
class _DiscAsset extends BaseAsset {
  final double radius;
  int taps = 0;

  _DiscAsset({required this.radius}) {
    coordinates = Coordinates(x: 0.25, y: 0.5);
    size = const RelativeSize(width: 0.2, height: 0.2);
  }

  @override
  String get displayName => 'DiscAsset';

  @override
  String get category => 'Test';

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // The painter is handed its box rather than remembering one from the
        // last paint: a rebuild whose `shouldRepaint` says no installs the
        // new painter WITHOUT painting it, so a remembered size is stale — and
        // a painter that hit-tests against a stale size hit-tests nothing.
        // `ConveyorPainter` takes its `paintSize` for the same reason.
        builder: (context, constraints) {
          final painter = _DiscPainter(radius, constraints.biggest);
          return GestureDetector(
            // deferToChild: the painter decides, so the disc decides.
            onTap: () {
              taps++;
              showSidePane(
                context: context,
                id: 'pane:disc',
                builder: (_) => const Text('pane disc'),
              );
            },
            // The same path the painter hit-tests against, handed over as-is
            // — the contract [AssetHitShape] is for.
            child: AssetHitShape(
              shape: () => painter.shape,
              child: CustomPaint(key: discKey, painter: painter),
            ),
          );
        },
      );

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: 'DiscAsset'};
}

/// Identifies the disc asset's painted surface.
const Key discKey = ValueKey('disc-asset');

class _DiscPainter extends CustomPainter {
  final double radius;
  final Size box;

  const _DiscPainter(this.radius, this.box);

  /// One derivation, two callers: [hitTest] answers from it and the asset
  /// publishes it.
  Path get shape => Path()
    ..addOval(Rect.fromCircle(center: box.center(Offset.zero), radius: radius));

  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
        size.center(Offset.zero),
        radius,
        Paint()..color = const Color(0xFF888888),
      );

  @override
  bool hitTest(Offset position) => shape.contains(position);

  @override
  bool shouldRepaint(_DiscPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.box != box;
}

/// A composite asset the way the Beckhoff racks are one: two pane-opening
/// slices drawn inside the parent's box, each in its own [SubdeviceSubject].
class _RackAsset extends BaseAsset {
  final _PaneAsset sliceA = _PaneAsset('sliceA', x: 0.5);
  final _PaneAsset sliceB = _PaneAsset('sliceB', x: 0.5);

  _RackAsset() {
    // Left of centre so the docked pane never covers slice B.
    coordinates = Coordinates(x: 0.3, y: 0.5);
    size = const RelativeSize(width: 0.4, height: 0.2);
  }

  @override
  String get displayName => 'RackAsset';

  @override
  String get category => 'Test';

  @override
  List<Asset> get childAssets => [sliceA, sliceB];

  @override
  Widget build(BuildContext context) => Row(
        key: rackRowKey,
        children: [
          for (final slice in [sliceA, sliceB])
            Expanded(
              child: SubdeviceSubject(
                subdevice: slice,
                // Through a Builder so the slice opens its pane from a
                // context inside its own subject — the same shape
                // `AssetStack` gives top-level assets.
                child: Builder(builder: slice.build),
              ),
            ),
        ],
      );

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: 'RackAsset'};
}

/// Identifies the rack's whole row, for "smaller than the rack" bounds.
const Key rackRowKey = ValueKey('rack-row');

/// An asset that opens a pane from its own build context, the way every
/// pane-owning asset in the app does.
class _PaneAsset extends BaseAsset {
  final String name;
  int taps = 0;

  _PaneAsset(this.name, {required double x}) {
    coordinates = Coordinates(x: x, y: 0.5);
    size = const RelativeSize(width: 0.2, height: 0.2);
  }

  @override
  String get displayName => 'PaneAsset';

  @override
  String get category => 'Test';

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () {
          taps++;
          showSidePane(
            context: context,
            id: 'pane:$name',
            builder: (_) => Text('pane $name'),
          );
        },
        child: ColoredBox(
          key: ValueKey('face:$name'),
          color: const Color(0xFF888888),
          child: Center(child: Text(name)),
        ),
      );

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {constAssetName: 'PaneAsset'};
}

// Regression tests for the rotation-of-selection-chrome / gesture-detector
// bug reported by operators editing rotated sensors.
//
// Before this fix, the editor's blue selection rectangle and the runtime
// GestureDetector hit area were always drawn axis-aligned at the asset's
// pre-rotation bounding box. After rotating an asset via `Coordinates.angle`,
// the visual would rotate (each asset uses `LayoutRotatedBox` / `Transform.rotate`
// internally) but the selection chrome and tap-target stayed unrotated --
// resulting in clicks landing outside the visible glyph being captured,
// and selecting an asset showing the box in the wrong orientation.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Minimal test asset: a 40x10 (relative 0.4 x 0.1) coloured box.
///
/// The visual is intentionally rectangular and asymmetric so that
/// rotating it by 90 degrees produces a clearly different on-screen
/// footprint than the unrotated case.
///
/// Optionally wraps its visual in its OWN GestureDetector so we can
/// assert that runtime-mode taps reach the asset's internal handlers
/// (regression: an opaque overlay Container was swallowing them before).
class _TestBoxAsset extends BaseAsset {
  @override
  String get displayName => 'TestBox';
  @override
  String get category => 'Test';

  _TestBoxAsset({Coordinates? coords, RelativeSize? sz, this.onInternalTap}) {
    if (coords != null) coordinates = coords;
    if (sz != null) size = sz;
  }

  final VoidCallback? onInternalTap;

  @override
  Widget build(BuildContext context) {
    // Match the production rotation pattern: rotate the visual via a
    // Transform.rotate so the painter follows angle. The page-view layer
    // is supposed to mirror that rotation on the selection chrome /
    // gesture detector but currently does not.
    Widget visual = const ColoredBox(color: Color(0xFFFF0000));
    if (onInternalTap != null) {
      // Mirrors production sensors / conveyors that wrap their painter in
      // their own GestureDetector(HitTestBehavior.opaque) for tap-to-
      // open-details. Runtime mode must let these fire.
      visual = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onInternalTap,
        child: visual,
      );
    }
    return Transform.rotate(
      angle: (coordinates.angle ?? 0.0) * math.pi / 180,
      child: visual,
    );
  }

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {
        constAssetName: 'TestBoxAsset',
        'x': coordinates.x,
        'y': coordinates.y,
        'angle': coordinates.angle,
      };
}

/// Wraps an [AssetStack] with the providers it needs (substitutionsChanged)
/// overridden out, sized to a known 100x100 viewport so coordinate math is
/// easy to reason about in assertions.
Widget _wrap({
  required List<Asset> assets,
  Set<Asset> selected = const {},
  bool absorb = false,
  void Function(Asset)? onTap,
}) {
  return ProviderScope(
    overrides: [
      // page_view watches substitutionsChangedProvider, which depends on
      // stateManProvider. We don't need real state in these tests; the
      // watch is fire-and-forget so an erroring provider is fine.
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: LayoutBuilder(
              builder: (context, constraints) => AssetStack(
                assets: assets,
                constraints: constraints,
                absorb: absorb,
                onTap: onTap,
                selectedAssets: selected,
                mirroringDisabled: true,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('Selection box rotates with asset angle', () {
    testWidgets(
      'selection chrome carries the same rotation as the asset visual',
      (tester) async {
        // Asset centered at 50,50 with size 40x10, rotated 90 degrees.
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5, angle: 90.0),
          sz: const RelativeSize(width: 0.4, height: 0.1),
        );

        await tester.pumpWidget(_wrap(
          assets: [asset],
          selected: {asset},
        ));
        await tester.pump();

        // Find the blue selection-border container.
        final borderedFinder = find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final dec = w.decoration;
          if (dec is! BoxDecoration) return false;
          final border = dec.border;
          if (border is! Border) return false;
          return border.top.color == Colors.blue;
        });
        expect(borderedFinder, findsOneWidget,
            reason:
                'Selection-border Container must exist when asset is selected');

        // Walk up the element tree looking for a Transform whose matrix
        // encodes the 90 degree rotation. Pre-fix this fails -- the only
        // Transform in the ancestor chain is the mirror identity matrix.
        final borderElement = tester.element(borderedFinder);
        var found90Rotation = false;
        borderElement.visitAncestorElements((element) {
          final widget = element.widget;
          if (widget is Transform) {
            // cos(pi/2)=0, sin(pi/2)=1
            final m = widget.transform;
            final c = m.entry(0, 0).abs();
            final s = m.entry(1, 0).abs();
            if (c < 0.01 && (s - 1.0).abs() < 0.01) {
              found90Rotation = true;
              return false;
            }
          }
          return true;
        });

        expect(found90Rotation, isTrue,
            reason:
                'Selection chrome must be wrapped in a 90 degree rotation transform so it follows the rotated visual');
      },
    );
  });

  group('Gesture-detector hit area rotates with asset angle', () {
    testWidgets(
      'tap inside the rotated visual (outside unrotated rect) fires onTap',
      (tester) async {
        // Asset at center (50,50), 40x10, rotated 90 degrees.
        // Visual after rotation occupies x in [45,55], y in [30,70].
        // The point (50, 32) is INSIDE the rotated visual but OUTSIDE the
        // unrotated 40x10 rect (which occupies x in [30,70], y in [45,55]).
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5, angle: 90.0),
          sz: const RelativeSize(width: 0.4, height: 0.1),
        );

        bool tapped = false;
        await tester.pumpWidget(_wrap(
          assets: [asset],
          absorb: true,
          onTap: (_) => tapped = true,
        ));
        await tester.pump();

        // Tap at the canvas-local point (50, 32).
        final canvas = tester.getRect(find.byType(AssetStack));
        await tester.tapAt(canvas.topLeft + const Offset(50, 32));
        await tester.pump();

        expect(tapped, isTrue,
            reason:
                'Tap inside the rotated visual must fire onTap; currently the GestureDetector hit area is the unrotated rect so the tap is missed');
      },
    );

    testWidgets(
      'tap outside the rotated visual (but inside unrotated rect) does NOT fire onTap',
      (tester) async {
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5, angle: 90.0),
          sz: const RelativeSize(width: 0.4, height: 0.1),
        );

        bool tapped = false;
        await tester.pumpWidget(_wrap(
          assets: [asset],
          absorb: true,
          onTap: (_) => tapped = true,
        ));
        await tester.pump();

        // The point (35, 50) is inside the UNROTATED rect (x in [30,70],
        // y in [45,55]) but OUTSIDE the rotated visual (x must be in [45,55]).
        final canvas = tester.getRect(find.byType(AssetStack));
        await tester.tapAt(canvas.topLeft + const Offset(35, 50));
        await tester.pump();

        expect(tapped, isFalse,
            reason:
                'Tap outside the rotated visual must NOT fire onTap; currently the unrotated GestureDetector swallows clicks the operator never sees a target for');
      },
    );
  });

  group('Gestures propagate through translation + asset angle', () {
    testWidgets(
      'tap on rotated asset still fires when wrapped in a translating parent',
      (tester) async {
        // Regression for the project memory note
        // `feedback_gesture_through_translation`: children of an elevator
        // (modelled here as a Transform.translate) must keep their
        // GestureDetectors working during platform motion. We compound
        // that constraint with the asset's own rotation to ensure the
        // combined Transform.translate + Transform.rotate stack does not
        // break hit-testing.
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5, angle: 90.0),
          sz: const RelativeSize(width: 0.4, height: 0.1),
        );

        bool tapped = false;

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    // Simulate the elevator platform translating its
                    // children downward by 20 px. With transformHitTests
                    // = true (Transform.translate default), the rotated
                    // asset underneath must still receive taps at its
                    // new screen position.
                    child: Transform.translate(
                      offset: const Offset(0, 20),
                      child: LayoutBuilder(
                        builder: (context, constraints) => AssetStack(
                          assets: [asset],
                          constraints: constraints,
                          absorb: true,
                          onTap: (_) => tapped = true,
                          selectedAssets: const {},
                          mirroringDisabled: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // The asset visual lives at canvas centre (50, 50) rotated 90°,
        // so post-translation it occupies x in [45,55], y in [50, 90]
        // in screen space (a 20 px shift). Tap at (50, 70) which is
        // inside the translated rotated visual.
        final asResolved = tester
            .getRect(find.byType(AssetStack))
            .topLeft;
        // AssetStack's top-left is at the Center'd 100x100 SizedBox's
        // top-left, which has already absorbed the translation: tap
        // relative to the AssetStack at (50, 70 - 20) = (50, 50) would
        // be the un-translated centre. Since Transform.translate is
        // BETWEEN the SizedBox and AssetStack, AssetStack reports its
        // post-translation rect. So we tap at AssetStack-local (50, 32)
        // -- the same offset that lands inside the rotated visual in
        // the basic regression test above.
        await tester.tapAt(asResolved + const Offset(50, 32));
        await tester.pump();

        expect(tapped, isTrue,
            reason:
                'A rotated asset inside a translating parent must still receive taps (gesture-through-translation memory constraint).');
      },
    );
  });

  group('Runtime-mode primary taps reach asset internal GestureDetectors', () {
    // Regression: the selection-rotation fix wrapped the editor's
    // GestureDetector in a Container(decoration: BoxDecoration(border: ...)).
    // Even with border: null, BoxDecoration.hitTest returns true inside any
    // rectangular shape — so the Container was hit-test-opaque and swallowed
    // primary taps before they reached the asset's own GestureDetector. In
    // runtime mode (absorb=false, isSelected=false) operators could no longer
    // tap a sensor to open its details dialog. Fix: only wrap in the bordered
    // Container when actually selected.
    testWidgets(
      'tap on an unrotated runtime asset reaches its internal GestureDetector',
      (tester) async {
        bool internalTapped = false;
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5),
          sz: const RelativeSize(width: 0.4, height: 0.1),
          onInternalTap: () => internalTapped = true,
        );

        await tester.pumpWidget(_wrap(
          assets: [asset],
          absorb: false, // runtime mode
        ));
        await tester.pump();

        // Tap at the canvas-local centre of the asset (50, 50).
        final canvas = tester.getRect(find.byType(AssetStack));
        await tester.tapAt(canvas.topLeft + const Offset(50, 50));
        await tester.pump();

        expect(internalTapped, isTrue,
            reason:
                'In runtime mode, primary taps must reach the asset\'s own GestureDetector. If false, the overlay chrome is intercepting hits (regression introduced by selection-rotation fix).');
      },
    );

    testWidgets(
      'tap on a rotated runtime asset reaches its internal GestureDetector',
      (tester) async {
        bool internalTapped = false;
        final asset = _TestBoxAsset(
          coords: Coordinates(x: 0.5, y: 0.5, angle: 90.0),
          sz: const RelativeSize(width: 0.4, height: 0.1),
          onInternalTap: () => internalTapped = true,
        );

        await tester.pumpWidget(_wrap(
          assets: [asset],
          absorb: false, // runtime mode
        ));
        await tester.pump();

        // Tap inside the rotated visual (vertical post-rotation: x in
        // [45,55], y in [30,70]). Centre (50, 50) lands cleanly inside.
        final canvas = tester.getRect(find.byType(AssetStack));
        await tester.tapAt(canvas.topLeft + const Offset(50, 50));
        await tester.pump();

        expect(internalTapped, isTrue,
            reason:
                'A rotated asset in runtime mode must still receive taps on its internal GestureDetector.');
      },
    );
  });
}

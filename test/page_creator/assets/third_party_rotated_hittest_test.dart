// Regression: a third-party-equipment asset must be tappable on its WHOLE
// visible box for every kind, at any aspect ratio and any rotation.
//
// The operator reported that tapping a rotated `ThirdPartyEquipmentConfig`
// (worst on the wide multivac, rotated 90 degrees) only opened the side pane
// over a thin central band — the top and bottom were dead.
//
// Cause: the opaque `GestureDetector` used to sit OUTSIDE the asset's
// `LayoutRotatedBox`. There the detector's render box keeps the asset's
// UN-rotated w x h size, so once the box is rotated its opaque hit area (the
// un-rotated rect) and the visible glyph (the rotated rect) overlap only in a
// central `min(w,h) x min(w,h)` square. On a wide box turned 90 degrees that
// square is a thin band. Moving the detector INSIDE the rotated box, wrapping
// the full-size body, lets `_RenderLayoutRotatedBox.hitTest` map every tap into
// the child's un-rotated frame first — so the entire placed box is live. Same
// fix, same contract, as `sensor_rotated_hittest_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/third_party.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import '../../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  tearDown(closeSidePane);

  // Runtime placement (absorb: false) so the asset's own rotation-aware hit
  // test is exercised through the real `AssetStack` layering the operator
  // taps: OverflowBox + `_HitPermissiveSizedBox` + the asset's internal
  // `LayoutRotatedBox`. On the default 800x600 test surface a RelativeSize of
  // (w, h) lays out as (w*800) x (h*600) pixels.
  Widget stackApp(ThirdPartyEquipmentConfig config) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: LayoutBuilder(
            builder: (context, constraints) => AssetStack(
              assets: [config],
              constraints: constraints,
              absorb: false,
              selectedAssets: const {},
              mirroringDisabled: true,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> expectTapOpensPane(
    WidgetTester tester,
    Offset globalPos,
    String what,
  ) async {
    await tester.tapAt(globalPos);
    // Pumped rather than settled: the plant view rings the asset whose pane
    // is open, and the ring's dashes crawl for as long as it is up — there is
    // no settled state to wait for while a pane is showing. Two frames is the
    // pane's own build and the post-frame trace of the asset's hit test.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(SidePane), findsOneWidget,
        reason: 'Tapping the $what must open the details pane.');
    closeSidePane();
    // Settles again once it is closed: the crawl stops with the ring.
    await tester.pumpAndSettle();
  }

  Future<void> expectTapMisses(
    WidgetTester tester,
    Offset globalPos,
    String what,
  ) async {
    await tester.tapAt(globalPos);
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsNothing,
        reason: 'A tap on the $what must not open the pane.');
  }

  // Every kind, sized to a WIDE box (400x60) and rotated 90 degrees so the
  // visible glyph is a 60x400 vertical strip centred on the asset. Under the
  // old arrangement only a 60x60 central square was live; the ends here sit
  // +/-160 px from centre, far outside it. Driven off the enum so a new kind
  // cannot slip through untested.
  for (final kind in ThirdPartyEquipmentKind.values) {
    testWidgets('${kind.name}: the whole rotated box is tappable, not just a '
        'central band', (tester) async {
      final config = ThirdPartyEquipmentConfig(kind: kind)
        ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
        ..size = const RelativeSize(width: 0.5, height: 0.1);
      await tester.pumpWidget(stackApp(config));
      await tester.pumpAndSettle();

      final center = tester.getCenter(find.byType(ThirdPartyEquipment));
      await expectTapOpensPane(tester, center, '${kind.name} centre');
      await expectTapOpensPane(
          tester, center + const Offset(0, -160), '${kind.name} top end');
      await expectTapOpensPane(
          tester, center + const Offset(0, 160), '${kind.name} bottom end');
    });
  }

  testWidgets('multivac (wide, 5.4:1) rotated 90: all four corners of the '
      'rotated box open the pane', (tester) async {
    // 400x60 un-rotated -> a 60x400 vertical strip after the 90 turn. Probe
    // near each corner of that strip (+/-28 x, +/-190 y) — every one lands
    // outside the old central square.
    final config = ThirdPartyEquipmentConfig(
      kind: ThirdPartyEquipmentKind.multivac,
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
      ..size = const RelativeSize(width: 0.5, height: 0.1);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    final c = tester.getCenter(find.byType(ThirdPartyEquipment));
    await expectTapOpensPane(tester, c + const Offset(-28, -190), 'top-left');
    await expectTapOpensPane(tester, c + const Offset(28, -190), 'top-right');
    await expectTapOpensPane(tester, c + const Offset(-28, 190), 'bottom-left');
    await expectTapOpensPane(tester, c + const Offset(28, 190), 'bottom-right');
  });

  testWidgets('boxErector (portrait) rotated 90: the swapped left/right ends '
      'open the pane', (tester) async {
    // The portrait counterpart: 80x240 un-rotated -> a 240x80 horizontal strip
    // after the turn. The old central square was only 80x80, so the far
    // left/right ends (+/-100 x) were the dead region here.
    final config = ThirdPartyEquipmentConfig(
      kind: ThirdPartyEquipmentKind.boxErector,
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
      ..size = const RelativeSize(width: 0.1, height: 0.4);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    final c = tester.getCenter(find.byType(ThirdPartyEquipment));
    await expectTapOpensPane(tester, c, 'centre');
    await expectTapOpensPane(tester, c + const Offset(-100, -28), 'left end');
    await expectTapOpensPane(tester, c + const Offset(100, 28), 'right end');
  });

  testWidgets('the hit area follows the rotated glyph — a tap beside it misses',
      (tester) async {
    // A point INSIDE the old un-rotated 400x60 rect but OUTSIDE the 60x400
    // rotated strip. The old (buggy) opaque box would have caught it; the
    // fixed hit test, tracking the visible glyph, must let it fall through —
    // proving the fix did not simply widen the target to the whole AABB.
    final config = ThirdPartyEquipmentConfig(
      kind: ThirdPartyEquipmentKind.multivac,
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
      ..size = const RelativeSize(width: 0.5, height: 0.1);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byType(ThirdPartyEquipment));
    await expectTapMisses(
        tester, center + const Offset(70, 0), 'gap beside the rotated strip');
  });
}

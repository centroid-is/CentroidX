// Regression: a rotated sensor must be tappable on its whole visible glyph.
//
// AssetStack lays a rotated asset out in its unrotated w×h rect and lets the
// asset's internal `LayoutRotatedBox` paint out into the surrounding AABB.
// Before the `_HitPermissiveSizedBox` fix in `lib/pages/page_view.dart` (and
// moving the sensor's GestureDetector inside its `LayoutRotatedBox`), hits
// were clamped to the unrotated rect first — so a 90°-rotated optic sensor
// was only tappable on the sliver where the rotated visual overlaps that
// rect: the middle of the cone, never the housing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/sensor.dart';
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

  Widget stackApp(SensorConfig config) {
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

  testWidgets('unrotated sensor: housing, cone and corners are tappable',
      (tester) async {
    final config = SensorConfig(kind: SensorKind.opticField)
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.1, height: 0.05);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    final origin = tester.getTopLeft(find.byType(Sensor));
    final size = tester.getSize(find.byType(Sensor));
    await expectTapOpensPane(
        tester, origin + Offset(size.width * 0.17, size.height * 0.5),
        'housing');
    await expectTapOpensPane(
        tester, origin + Offset(size.width * 0.6, size.height * 0.5), 'cone');
    await expectTapOpensPane(tester, origin + const Offset(2, 2), 'corner');
  });

  testWidgets('90°-rotated sensor: the whole rotated glyph is tappable',
      (tester) async {
    final config = SensorConfig(kind: SensorKind.opticField)
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
      ..size = const RelativeSize(width: 0.1, height: 0.05);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    // The laid-out widget keeps its unrotated 80×30 rect; the VISUAL is the
    // 30×80 rotated glyph centered on the same point. Probe along the
    // vertical glyph: housing end, middle, cone-base end. The end points
    // sit well outside the unrotated rect — exactly the region the old
    // SizedBox clamp used to swallow.
    final center = tester.getCenter(find.byType(Sensor));
    await expectTapOpensPane(tester, center, 'rotated glyph middle');
    await expectTapOpensPane(
        tester, center + const Offset(0, -30), 'rotated housing end');
    await expectTapOpensPane(
        tester, center + const Offset(0, 30), 'rotated cone-base end');
  });

  testWidgets('taps beside the rotated glyph still fall through',
      (tester) async {
    final config = SensorConfig(kind: SensorKind.opticField)
      ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: 90)
      ..size = const RelativeSize(width: 0.1, height: 0.05);
    await tester.pumpWidget(stackApp(config));
    await tester.pumpAndSettle();

    // A point inside the unrotated rect but OUTSIDE the rotated glyph: the
    // permissive box must not widen the hit area beyond the visible pixels.
    final center = tester.getCenter(find.byType(Sensor));
    await tester.tapAt(center + const Offset(35, 0));
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsNothing,
        reason: 'The hit area follows the rotated visual — a tap beside the '
            'glyph (even inside the old unrotated rect) must miss.');
  });
}


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/zoomable_canvas.dart';
import '../helpers/golden_platform.dart';

/// What an operator sees when a docked side pane opens over a conveyor.
///
/// The plant view is an aspect-locked canvas, so yielding the strip the pane
/// occupies re-fits the whole page: on this 1280x800 window the canvas goes
/// from 1280x720 to 876x493, and every asset on it gets 0.68x smaller. That
/// part is by design and reads fine.
///
/// A conveyor with turns used to do something else — it *reshaped*. The fit
/// that lays a turned belt into its box was decided partly in absolute
/// pixels, so the same belt in the same-shaped box came out differently at a
/// different size, and a belt near one of the fit's accept boundaries dropped
/// from filling its box to a fraction of it. These two goldens are the same
/// page a pane apart: the belts must differ only in scale.
///
/// The serpentine here — two U-turns, four bends — is one of the belts that
/// flipped; the straight belt above it is the control that never did.
const _background = Color(0xFF1A1A2E);

ConveyorConfig _serpentine() => ConveyorConfig.preview()
  ..coordinates = Coordinates(x: 0.72, y: 0.58)
  ..size = const RelativeSize(width: 0.425, height: 0.375)
  ..beltThickness = 0.35
  ..turns.addAll([
    for (var i = 0; i < 4; i++)
      ConveyorTurnEntry(
        position: (i + 1) / 5,
        angle: (i ~/ 2) % 2 == 0 ? 90 : -90,
        radius: 0.3,
      )
  ]);

ConveyorConfig _straight() => ConveyorConfig.preview()
  ..coordinates = Coordinates(x: 0.72, y: 0.14)
  ..size = const RelativeSize(width: 0.425, height: 0.06);

/// The plant view, cut down to what matters here: [SidePaneInset] over a
/// [ZoomableCanvas], with assets laid out the way `AssetStack` lays them out
/// — fractions of the canvas box, centred on their coordinates.
Widget _plantView(List<ConveyorConfig> assets) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: _background,
        body: SidePaneInset(
          child: ZoomableCanvas(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  children: [
                    for (final config in assets)
                      Positioned(
                        left:
                            config.coordinates.x * w - config.size.width * w / 2,
                        top: config.coordinates.y * h -
                            config.size.height * h / 2,
                        width: config.size.width * w,
                        height: config.size.height * h,
                        child: Conveyor(config),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('side pane inset vs a turned conveyor',
      skip: goldenSkip, () {
    Future<void> pumpPage(WidgetTester tester) async {
      // Wide enough that the canvas is height-bound before the pane opens and
      // width-bound after, which is what makes the re-fit shrink it.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_plantView([_straight(), _serpentine()]));
      await tester.pumpAndSettle();
    }

    testWidgets('pane closed: the page at full size', (tester) async {
      await pumpPage(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_uturn_pane_closed.png'),
      );
    });

    testWidgets('pane open: the same belts, 0.68x smaller and nothing else',
        (tester) async {
      await pumpPage(tester);
      showSidePane(
        context: tester.element(find.byType(ZoomableCanvas)),
        id: 'conveyor:CN01',
        // The conveyors sit under the pane, so the page yields the strip.
        avoidRect: const Rect.fromLTWH(1000, 100, 200, 200),
        builder: (_) => const SidePane(
          title: 'CN-01',
          subtitle: 'Serpentine, two U-turns',
          icon: Icons.conveyor_belt,
          status: PaneStatus.running(),
          child: SizedBox(height: 200),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(closeSidePane);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/conveyor_uturn_pane_open.png'),
      );
    });
  });
}

/// A page can refuse zoom and pan (`AssetPage.zoomPanDisabled`), which the
/// plant view hands to `ZoomableCanvas.interactive`.
///
/// Locked has to mean every way in: the mouse wheel, a pinch, a trackpad
/// pinch, and the middle button — which otherwise pans unconditionally. A
/// page locked while zoomed snaps back to 1:1, because no gesture is left to
/// get it back there.
library;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/pages/page_view.dart';
import 'package:tfc/providers/page_manager.dart';
import 'package:tfc/widgets/zoomable_canvas.dart';
import 'package:tfc_dart/core/preferences.dart';

TransformationController _controller(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!;

double _scale(WidgetTester tester) =>
    _controller(tester).value.getMaxScaleOnAxis();

Widget _canvas({required bool interactive}) => MaterialApp(
      home: Scaffold(
        body: ZoomableCanvas(
          interactive: interactive,
          child: const SizedBox.expand(),
        ),
      ),
    );

Future<void> _wheelIn(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(InteractiveViewer));
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
  await tester.pumpAndSettle();
}

Future<void> _pinchOut(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(InteractiveViewer));
  final a = await tester.startGesture(center - const Offset(20, 0));
  final b = await tester.startGesture(center + const Offset(20, 0));
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await a.moveBy(const Offset(-20, 0));
    await b.moveBy(const Offset(20, 0));
    await tester.pump();
  }
  await a.up();
  await b.up();
  await tester.pumpAndSettle();
}

Future<void> _trackpadPinch(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(InteractiveViewer));
  final pointer = TestPointer(2, PointerDeviceKind.trackpad);
  await tester.sendEventToBinding(pointer.panZoomStart(center));
  await tester.pump();
  for (var i = 1; i <= 5; i++) {
    await tester.sendEventToBinding(
        pointer.panZoomUpdate(center, scale: 1 + i * 0.3));
    await tester.pump();
  }
  await tester.sendEventToBinding(pointer.panZoomEnd());
  await tester.pumpAndSettle();
}

Future<void> _middleDrag(WidgetTester tester, Offset by) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(InteractiveViewer)),
    kind: PointerDeviceKind.mouse,
    buttons: kMiddleMouseButton,
  );
  await tester.pump();
  await gesture.moveBy(by / 2);
  await tester.pump();
  await gesture.moveBy(by / 2);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Zooms to 2x, centred, so a pan has somewhere to go.
Future<void> _zoomToTwice(WidgetTester tester) async {
  final viewport = tester.getRect(find.byType(InteractiveViewer));
  _controller(tester).value = Matrix4.identity()
    ..translateByDouble(-viewport.width / 2, -viewport.height / 2, 0, 1)
    ..scaleByDouble(2, 2, 2, 1);
  await tester.pump();
}

void main() {
  group('ZoomableCanvas(interactive: false)', () {
    testWidgets('the mouse wheel zooms an ordinary canvas', (tester) async {
      // The control for the test below: proves the wheel event is one the
      // canvas would act on, so "did not zoom" there means locked, not missed.
      await tester.pumpWidget(_canvas(interactive: true));
      await _wheelIn(tester);
      expect(_scale(tester), greaterThan(1.0));
    });

    testWidgets('the mouse wheel does not zoom', (tester) async {
      await tester.pumpWidget(_canvas(interactive: false));
      await _wheelIn(tester);
      expect(_scale(tester), 1.0);
    });

    testWidgets('a pinch zooms an ordinary canvas', (tester) async {
      await tester.pumpWidget(_canvas(interactive: true));
      await _pinchOut(tester);
      expect(_scale(tester), greaterThan(1.0));
    });

    testWidgets('a pinch does not zoom', (tester) async {
      await tester.pumpWidget(_canvas(interactive: false));
      await _pinchOut(tester);
      expect(_scale(tester), 1.0);
    });

    testWidgets('a trackpad pinch zooms an ordinary canvas', (tester) async {
      await tester.pumpWidget(_canvas(interactive: true));
      await _trackpadPinch(tester);
      expect(_scale(tester), greaterThan(1.0));
    });

    testWidgets('a trackpad pinch does not zoom', (tester) async {
      await tester.pumpWidget(_canvas(interactive: false));
      await _trackpadPinch(tester);
      expect(_scale(tester), 1.0);
    });

    testWidgets('a middle-button drag does not pan', (tester) async {
      // Zoomed programmatically, so the pan has room to move and a refusal
      // is the flag's doing rather than 1:1 pinning the translation.
      await tester.pumpWidget(_canvas(interactive: false));
      await _zoomToTwice(tester);

      final before = _controller(tester).value.getTranslation();
      await _middleDrag(tester, const Offset(-60, -40));
      final after = _controller(tester).value.getTranslation();

      expect(after.x, before.x, reason: 'locked means the middle button too');
      expect(after.y, before.y);
    });

    testWidgets('locking a zoomed canvas snaps it back to 1:1', (tester) async {
      await tester.pumpWidget(_canvas(interactive: true));
      await _zoomToTwice(tester);
      expect(_scale(tester), 2.0);

      await tester.pumpWidget(_canvas(interactive: false));
      await tester.pump();

      expect(_scale(tester), 1.0,
          reason: 'with zoom locked there is no gesture left to zoom back out');
      expect(find.byTooltip(RegExp('Reset zoom')), findsNothing);
    });
  });

  group('PlantPageView', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    Future<void> pumpPage(WidgetTester tester, {required bool disabled}) async {
      final manager = PageManager(
        pages: {
          '/line-1': AssetPage(
            menuItem: const MenuItem(
                label: 'Line 1', path: '/line-1', icon: Icons.factory),
            assets: [],
            mirroringDisabled: false,
            zoomPanDisabled: disabled,
          ),
        },
        prefs: InMemoryPreferences(),
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          pageManagerProvider.overrideWith((ref) async => manager),
          bootstrapPageManagerProvider.overrideWithValue(manager),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlantPageView(pageName: '/line-1')),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a page with zoom and pan disabled cannot be zoomed',
        (tester) async {
      await pumpPage(tester, disabled: true);
      expect(
          tester.widget<ZoomableCanvas>(find.byType(ZoomableCanvas)).interactive,
          isFalse);
      await _wheelIn(tester);
      expect(_scale(tester), 1.0);
    });

    testWidgets('an ordinary page still zooms', (tester) async {
      await pumpPage(tester, disabled: false);
      expect(
          tester.widget<ZoomableCanvas>(find.byType(ZoomableCanvas)).interactive,
          isTrue);
      await _wheelIn(tester);
      expect(_scale(tester), greaterThan(1.0));
    });
  });
}

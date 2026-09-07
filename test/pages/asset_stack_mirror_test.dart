import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// The page-wide mirror (`AssetStackConfig`) flips every asset's *position*,
/// but the glyph flip is skipped for unrotated assets so text faces stay
/// readable on mirrored stations. A conveyor's turn is chiral — a left bend
/// must become a right bend or the mirrored page shows a belt that does not
/// exist on the floor — so `ConveyorConfig` opts back into the glyph flip via
/// `Asset.mirrorsWithPage`, and the painter is told the flags through
/// `AssetMirrorScope` so it can counter-mirror the text it draws itself.
///
/// Pinned here:
///  * an unrotated conveyor gets the mirror transform;
///  * a generic unrotated asset still does not (the readable-text contract);
///  * `ConveyorPainter` receives the effective mirror flags;
///  * a page with `mirroringDisabled` gets neither.
void main() {
  void seedPrefs({bool xMirror = false, bool yMirror = false}) {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      'asset_stack_config':
          jsonEncode({'xMirror': xMirror, 'yMirror': yMirror}),
    });
    // And the store the canvas actually reads since v1.2 plan 01-05 — the one
    // `initDeviceLocalPreferences()` opens, not a wrapper over the platform
    // instance above.
    useInMemoryDeviceLocalPreferences().setString(
      'asset_stack_config',
      jsonEncode({'xMirror': xMirror, 'yMirror': yMirror}),
    );
  }

  ConveyorConfig turnedConveyor() => ConveyorConfig.preview()
    ..coordinates = Coordinates(x: 0.4, y: 0.5)
    ..size = const RelativeSize(width: 0.5, height: 0.4)
    ..beltThickness = 0.15
    ..turns.add(ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5));

  /// The mirror transform `AssetStack` wraps a visual in: the nearest
  /// `Transform` ancestor. (The rotated selection frame is a sibling, and
  /// the conveyor rotates via `LayoutRotatedBox`, so this cannot pick up
  /// either.)
  Matrix4 wrappingMatrix(WidgetTester tester, Finder visual) {
    final transform = tester.widget<Transform>(
      find.ancestor(of: visual, matching: find.byType(Transform)).first,
    );
    return transform.transform;
  }

  ConveyorPainter conveyorPainter(WidgetTester tester) {
    final paints = tester.widgetList<CustomPaint>(find.descendant(
        of: find.byType(Conveyor), matching: find.byType(CustomPaint)));
    return paints
        .map((p) => p.painter)
        .whereType<ConveyorPainter>()
        .single;
  }

  Future<void> pumpStack(
    WidgetTester tester,
    List<Asset> assets, {
    bool mirroringDisabled = false,
  }) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: LayoutBuilder(
                builder: (context, constraints) => AssetStack(
                  assets: assets,
                  constraints: constraints,
                  selectedAssets: const {},
                  mirroringDisabled: mirroringDisabled,
                  absorb: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    // One frame for the config FutureBuilder to resolve, one to rebuild.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('x-mirror flips an unrotated conveyor but not a generic asset',
      (tester) async {
    seedPrefs(xMirror: true);
    final conveyor = turnedConveyor();
    final probe = _TextFaceAsset();
    await pumpStack(tester, [conveyor, probe]);

    final conveyorMatrix = wrappingMatrix(tester, find.byType(Conveyor));
    expect(conveyorMatrix.storage[0], -1.0,
        reason: 'the turn is chiral: the glyph must flip with the page');
    expect(conveyorMatrix.storage[5], 1.0);

    final probeMatrix = wrappingMatrix(tester, find.text('face'));
    expect(probeMatrix.isIdentity(), isTrue,
        reason: 'unrotated text faces keep skipping the flip so they '
            'stay readable');

    final painter = conveyorPainter(tester);
    expect(painter.mirrorX, isTrue,
        reason: 'the painter counter-mirrors its own text against the '
            'outer flip');
    expect(painter.mirrorY, isFalse);
  });

  testWidgets('y-mirror flips the conveyor vertically', (tester) async {
    seedPrefs(yMirror: true);
    await pumpStack(tester, [turnedConveyor()]);

    final matrix = wrappingMatrix(tester, find.byType(Conveyor));
    expect(matrix.storage[0], 1.0);
    expect(matrix.storage[5], -1.0);
    expect(conveyorPainter(tester).mirrorY, isTrue);
  });

  testWidgets('mirroringDisabled turns the flip off for the whole page',
      (tester) async {
    seedPrefs(xMirror: true, yMirror: true);
    await pumpStack(tester, [turnedConveyor()], mirroringDisabled: true);

    final matrix = wrappingMatrix(tester, find.byType(Conveyor));
    expect(matrix.isIdentity(), isTrue);
    final painter = conveyorPainter(tester);
    expect(painter.mirrorX, isFalse);
    expect(painter.mirrorY, isFalse);
  });

  // The flip `AssetStack` puts around the whole visual would render the
  // frequency figure backwards; the painter undoes it for the text it draws
  // itself, the way it already counter-rotates against `coordinates.angle`.
  // Pinned by recording the canvas ops rather than a golden: the painter's
  // TextStyle names no font family, so the test binding rasterises the
  // digits as Ahem boxes — mirror-symmetric, invisible to a golden.
  test('painter counter-mirrors its text between counter-rotate and draw',
      () {
    ConveyorPainter painter({required bool mirrorX, required bool mirrorY}) =>
        ConveyorPainter(
          color: Colors.green,
          batches: const {},
          angle: 0,
          showFrequency: true,
          frequency: 42.5,
          mirrorX: mirrorX,
          mirrorY: mirrorY,
        );

    var canvas = _RecordingCanvas();
    painter(mirrorX: true, mirrorY: false).paint(canvas, const Size(300, 60));
    var i = canvas.ops.indexOf('scale(-1.0, 1.0)');
    expect(i, greaterThanOrEqualTo(0),
        reason: 'x-mirror must be undone before the text paints');
    expect(canvas.ops.sublist(i), contains('drawParagraph'),
        reason: 'the counter-scale must come before the text, not after');

    canvas = _RecordingCanvas();
    painter(mirrorX: false, mirrorY: true).paint(canvas, const Size(300, 60));
    i = canvas.ops.indexOf('scale(1.0, -1.0)');
    expect(i, greaterThanOrEqualTo(0));
    expect(canvas.ops.sublist(i), contains('drawParagraph'));

    canvas = _RecordingCanvas();
    painter(mirrorX: false, mirrorY: false)
        .paint(canvas, const Size(300, 60));
    expect(canvas.ops.where((op) => op.startsWith('scale')), isEmpty,
        reason: 'no mirror, no counter-scale');
  });
}

/// Records the op sequence [ConveyorPainter] emits; every other Canvas call
/// is swallowed by [noSuchMethod].
class _RecordingCanvas implements Canvas {
  final ops = <String>[];

  @override
  void scale(double sx, [double? sy]) => ops.add('scale($sx, ${sy ?? sx})');

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) =>
      ops.add('drawParagraph');

  @override
  void noSuchMethod(Invocation invocation) {}
}

/// A minimal unrotated asset with a readable face — the kind of asset the
/// null-angle skip exists for.
class _TextFaceAsset extends BaseAsset {
  _TextFaceAsset() {
    coordinates = Coordinates(x: 0.8, y: 0.2);
    size = const RelativeSize(width: 0.2, height: 0.2);
  }

  @override
  Widget build(BuildContext context) => const Text('face');

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {};
}

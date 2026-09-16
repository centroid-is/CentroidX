/// A cable plugged into nothing, driven through the real page editor.
///
/// Its handles are placed from its points and the stack paints it inside its
/// box, so every edit has to keep those two telling the same story: the
/// handles on the line, and the box round the handles. They used to be two
/// unrelated things -- the line drawn across the box, the handles at stored
/// ends nothing ever moved -- so dragging or resizing the cable left its
/// handles behind at a different place and scale.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_anchors.dart';
import 'package:tfc/page_creator/assets/link_edit_overlay.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/pages/page_view.dart';

import '../helpers/page_editor_harness.dart';

void main() {
  setUp(setUpEditorEnvironment);

  Rect canvasRect(WidgetTester tester) =>
      tester.getRect(find.byType(AssetStack));

  /// The editor's own copies, not the ones handed to it.
  List<Asset> live(WidgetTester tester) =>
      tester.widget<AssetStack>(find.byType(AssetStack)).assets;

  EtherCatLinkConfig cable(WidgetTester tester) =>
      live(tester).whereType<EtherCatLinkConfig>().single;

  /// The run as the painter and the overlay both resolve it, on screen.
  ResolvedLink run(WidgetTester tester) {
    final r = canvasRect(tester);
    final resolved = cable(tester)
        .run
        .resolve(r.size, PageLinkAnchors(live(tester), r.size));
    return ResolvedLink(
      [for (final p in resolved.points) r.topLeft + p],
      resolved.frame,
      resolved.canvas,
      resolved.radius,
    );
  }

  List<Offset> handleCentres(WidgetTester tester) => [
        for (final e in find
            .descendant(
              of: find.byType(LinkEditOverlay),
              matching: find.byWidgetPredicate(
                  (w) => w.runtimeType.toString() == '_Handle'),
            )
            .evaluate())
          tester.getCenter(find.byWidget(e.widget)),
      ];

  /// The invariant this file exists for.
  void expectHandlesOnTheCable(WidgetTester tester, String when) {
    final handles = handleCentres(tester);
    expect(handles, isNotEmpty, reason: '$when: the cable is not selected');
    final line = run(tester);
    final frame = tester.getRect(find.byKey(ObjectKey(cable(tester))));
    for (final h in handles) {
      expect(line.distanceTo(h), lessThan(1.0),
          reason: '$when: handle at $h is off the drawn line');
      expect(frame.inflate(1).contains(h), isTrue,
          reason: '$when: handle at $h is outside the box the cable is '
              'painted in ($frame)');
    }
    // And the box is the run's, not a stale one around it.
    final pts = line.points;
    final xs = pts.map((p) => p.dx), ys = pts.map((p) => p.dy);
    final stroke = cable(tester).thickness * canvasRect(tester).width;
    expect(frame.left,
        closeTo(xs.reduce((a, b) => a < b ? a : b) - stroke, 1.5),
        reason: '$when: the box does not follow the points');
    expect(frame.right,
        closeTo(xs.reduce((a, b) => a > b ? a : b) + stroke, 1.5),
        reason: '$when: the box does not follow the points');
    expect(frame.top.round(),
        lessThanOrEqualTo(ys.reduce((a, b) => a < b ? a : b).round()),
        reason: '$when: the box does not follow the points');
  }

  Future<void> drag(WidgetTester tester, Offset from, Offset by) async {
    // Many small moves: the editor's double-tap recognizer holds the arena,
    // and the first moves of a drag are swallowed while it does.
    final g = await tester.startGesture(from);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(from + by * (i / 10));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester) async {
    final pts = run(tester).points;
    await tester.tapAt(pts[0] * 0.8 + pts[1] * 0.2);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  Future<void> pumpCable(WidgetTester tester) => pumpEditorWith(tester, [
        EtherCatLinkConfig(
          run: LinkRun(waypoints: [LinkWaypoint.onRun(0.5, -0.3)]),
        )..coordinates = Coordinates(x: 0.3, y: 0.3),
      ]);

  testWidgets('selected, its handles sit on the line it is drawn as',
      (tester) async {
    await pumpCable(tester);
    await select(tester);
    expectHandlesOnTheCable(tester, 'selected');
  });

  testWidgets('dragging it carries the handles with it', (tester) async {
    await pumpCable(tester);
    await select(tester);
    final before = run(tester).points.first;

    final pts = run(tester).points;
    await drag(tester, pts[0] * 0.7 + pts[1] * 0.3, const Offset(200, 150));

    expect(run(tester).points.first.dx, greaterThan(before.dx + 100));
    expect(run(tester).points.first.dy, greaterThan(before.dy + 75));
    expectHandlesOnTheCable(tester, 'after dragging the cable');
  });

  testWidgets('an arrow nudge moves the run by exactly the nudge',
      (tester) async {
    await pumpCable(tester);
    await select(tester);
    final before = run(tester).points.first;
    await pressEditorKey(tester, LogicalKeyboardKey.arrowRight);
    expect(run(tester).points.first.dx, greaterThan(before.dx));
    expect(run(tester).points.first.dy, closeTo(before.dy, 1e-6));
    expectHandlesOnTheCable(tester, 'after an arrow nudge');
  });

  testWidgets('growing and shrinking scale the run, not a box beside it',
      (tester) async {
    await pumpCable(tester);
    await select(tester);
    double length() =>
        (run(tester).points.last - run(tester).points.first).distance;
    final before = length();

    await tester.tap(find.byTooltip('Grow selection'));
    await tester.pumpAndSettle();
    expect(length(), greaterThan(before * 1.05));
    expectHandlesOnTheCable(tester, 'after growing');

    await tester.tap(find.byTooltip('Shrink selection'));
    await tester.tap(find.byTooltip('Shrink selection'));
    await tester.pumpAndSettle();
    expect(length(), lessThan(before));
    expectHandlesOnTheCable(tester, 'after shrinking');
  });

  testWidgets('dragging a corner reshapes the box round it', (tester) async {
    await pumpCable(tester);
    await select(tester);
    final corner = run(tester).points[1];
    await drag(tester, corner, const Offset(0, -120));
    expect(run(tester).points[1].dy, lessThan(corner.dy - 60));
    expectHandlesOnTheCable(tester, 'after dragging a corner');
  });

  testWidgets('dragging an end stretches the run and its box', (tester) async {
    await pumpCable(tester);
    await select(tester);
    final end = run(tester).points.last;
    await drag(tester, end, const Offset(250, 200));
    expect(run(tester).points.last.dx, greaterThan(end.dx + 150));
    expectHandlesOnTheCable(tester, 'after dragging an end');

    // And the moved end is still carried by a drag of the whole cable.
    final pts = run(tester).points;
    final far = pts.last;
    await drag(tester, pts[0] * 0.7 + pts[1] * 0.3, const Offset(-80, 60));
    expect(run(tester).points.last.dx, lessThan(far.dx - 40));
    expectHandlesOnTheCable(tester, 'after dragging the stretched cable');
  });

  testWidgets('what is saved is what was drawn', (tester) async {
    final prefs = FakeEditorPreferences();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildEditorUnderTest(await editorManagerWith([
      EtherCatLinkConfig(
        run: LinkRun(waypoints: [LinkWaypoint.onRun(0.5, -0.3)]),
      )..coordinates = Coordinates(x: 0.3, y: 0.3),
    ], prefs)));
    await tester.pumpAndSettle();
    await select(tester);
    final pts = run(tester).points;
    await drag(tester, pts[0] * 0.7 + pts[1] * 0.3, const Offset(140, 0));
    final drawn = cable(tester).run.toJson();

    final saved = await saveAndReadBack(tester, prefs);
    final back = EtherCatLinkConfig.fromJson(saved.single);
    expect(back.run.from.x, closeTo(drawn['from']['x'] as double, 1e-9));
    expect(back.run.to.y, closeTo(drawn['to']['y'] as double, 1e-9));
  });
}

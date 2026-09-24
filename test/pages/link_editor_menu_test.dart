/// A selected cable, reached through the real page editor.
///
/// Selecting a cable puts its handles over the canvas, and that layer used to
/// answer the cable's clicks itself: a double-click did nothing and a
/// right-click offered only "Add point here", so a selected cable's form could
/// not be opened at all. These tests hold the editor's own gestures to working
/// on a cable exactly as they do on any other asset.
library;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
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

  List<Asset> live(WidgetTester tester) =>
      tester.widget<AssetStack>(find.byType(AssetStack)).assets;

  EtherCatLinkConfig cable(WidgetTester tester) =>
      live(tester).whereType<EtherCatLinkConfig>().single;

  /// The run's points on screen.
  List<Offset> points(WidgetTester tester) {
    final r = canvasRect(tester);
    return [
      for (final p in cable(tester)
          .run
          .resolve(r.size, PageLinkAnchors(live(tester), r.size))
          .points)
        r.topLeft + p,
    ];
  }

  /// A spot on the first segment, clear of the handles at its ends and the
  /// ghost in its middle.
  Offset onTheLine(WidgetTester tester) {
    final pts = points(tester);
    return pts[0] * 0.8 + pts[1] * 0.2;
  }

  Future<void> pumpSelectedCable(WidgetTester tester) async {
    await pumpEditorWith(tester, [
      EtherCatLinkConfig(
        run: LinkRun(waypoints: [LinkWaypoint.onRun(0.5, -0.3)]),
      )..coordinates = Coordinates(x: 0.4, y: 0.4),
    ]);
    await tester.tapAt(onTheLine(tester));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(LinkEditOverlay), findsOneWidget,
        reason: 'the cable should be selected');
  }

  /// The cable's configure form is up.
  final form = find.text('Link struct key');

  testWidgets('double-clicking a selected cable opens its form',
      (tester) async {
    await pumpSelectedCable(tester);
    expect(form, findsNothing);

    final at = onTheLine(tester);
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pumpAndSettle();

    expect(form, findsOneWidget);
  });

  testWidgets('right-clicking a selected cable opens the editor menu',
      (tester) async {
    await pumpSelectedCable(tester);

    await tester.tapAt(onTheLine(tester), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Add point here'), findsOneWidget);
    expect(find.text('Straighten run'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(form, findsOneWidget);
  });

  testWidgets('"Add point here" puts a corner where the cable was clicked',
      (tester) async {
    await pumpSelectedCable(tester);
    final at = onTheLine(tester);

    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add point here'));
    await tester.pumpAndSettle();

    expect(cable(tester).run.waypoints, hasLength(2));
    expect(points(tester)[1], within(distance: 1.0, from: at));
    expect(cable(tester).run.waypoints.every((w) => w.isOnPage), isTrue,
        reason: 'editing the cable settles its corners onto the page');
  });

  testWidgets('"Straighten run" removes every corner', (tester) async {
    await pumpSelectedCable(tester);

    await tester.tapAt(onTheLine(tester), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Straighten run'));
    await tester.pumpAndSettle();

    expect(cable(tester).run.waypoints, isEmpty);
  });
}

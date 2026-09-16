/// Every asset's config editor has to work inside the editor's side pane.
///
/// The pane replaced a `showDialog` that let each editor take almost the whole
/// screen — `configure()` bodies are still written against `media.width * 0.9`
/// — so the move to a docked strip is the first time these forms have had to
/// lay out narrow. Six of them did not: an inline HSV colour picker wants
/// ~680px, the composite bus-coupler editors are two columns, and a handful of
/// rows pinned their fields to fixed widths.
///
/// This walks the whole registry rather than a sample: the failure modes here
/// are silent ones — yellow-and-black stripes over content an engineer then
/// cannot reach, or a button that quietly navigates out of the editor — and a
/// new asset type is exactly when they reappear.
///
/// The pane is resizable, so an editor that needs more room has somewhere to
/// go — but it has to be usable at the width it opens at.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/ethercat_link.dart';
import 'package:tfc/page_creator/assets/link_geometry.dart';
import 'package:tfc/page_creator/assets/registry.dart';
import 'package:tfc/widgets/panes/side_pane.dart';

import '../helpers/page_editor_harness.dart';

void main() {
  setUp(setUpEditorEnvironment);

  for (final entry in AssetRegistry.defaultFactories.entries) {
    testWidgets('${entry.key} configures inside the pane', (tester) async {
      final asset = entry.value()
        ..coordinates = Coordinates(x: 0.3, y: 0.4)
        ..size = const RelativeSize(width: 0.12, height: 0.06);

      await pumpEditorWith(tester, [asset]);
      // Right-click, then "Edit": the editor has one mode now, so a plain tap
      // selects rather than opening the configuration.
      //
      // A cable only answers on its ink, and the palette's one is bent, so the
      // middle of its box is empty page: aim a little way along its first leg.
      var (fx, fy) = (0.3, 0.4);
      if (asset is EtherCatLinkConfig) {
        final frame = asset.run.frameIn(LinkAnchors.none);
        final bend = asset.run.boundsIn(LinkAnchors.none);
        final start = frame.start;
        final towards = asset.run.waypoints.isEmpty
            ? frame.end
            : frame.place(
                asset.run.waypoints.first.t!, asset.run.waypoints.first.n!);
        final at = start * 0.7 + towards * 0.3;
        expect(bend.contains(at), isTrue);
        (fx, fy) = (at.dx, at.dy);
      }
      await chooseFromAssetMenu(tester, fx, fy, 'Edit');

      expect(find.byType(SidePane), findsOneWidget,
          reason: '${entry.key} should open a config pane');
      expect(tester.takeException(), isNull,
          reason: "${entry.key}'s config editor does not fit the pane");

      // A config editor may not dismiss itself by popping the navigator.
      // Three of them used to end their header with a "Done" button calling
      // `Navigator.maybePop`. Inside the old config dialog that closed the
      // dialog; the pane is an overlay entry, not a route, so the same tap
      // now pops the page editor and drops the engineer out of it mid-edit.
      // The pane's action bar is the only thing that dismisses it.
      for (final label in ['Done', 'OK', 'Apply', 'Save']) {
        expect(
          find.descendant(
              of: find.byType(SidePane), matching: find.text(label)),
          findsNothing,
          reason: '${entry.key} offers its own "$label" inside the pane',
        );
      }

      // Leave nothing running: the pane drives a periodic watch while open.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
    });
  }
}

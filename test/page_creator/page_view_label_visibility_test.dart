// `Asset.showLabel` decides whether `AssetStack` paints an asset's [text]
// beside it on the page.
//
// Why the hook exists at all: for an asset that opens a side pane, the name is
// two things — the caption on the mimic and the title of the pane — so
// clearing the name to get a bare face on the page also leaves the pane
// untitled. `SectionButtonConfig.showName` is the first asset to separate the
// two, and this pins the page-view half of that contract.
//
// Contract under test:
//   - `showLabel == true` (the `BaseAsset` default) paints the label, so every
//     asset that never heard of this renders exactly as before;
//   - `showLabel == false` paints no label at all;
//   - a hidden label reserves no room either — the asset sits where it would
//     if it had no name, not offset by a caption nobody can see.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Minimal labelled asset whose `showLabel` the test drives directly.
class _LabelVisibilityTestAsset extends BaseAsset {
  @override
  String get displayName => 'LabelVisibilityTest';
  @override
  String get category => 'Test';

  final bool _showLabel;

  _LabelVisibilityTestAsset({
    required String labelText,
    bool showLabel = true,
    TextPos pos = TextPos.below,
  }) : _showLabel = showLabel {
    coordinates = Coordinates(x: 0.5, y: 0.5);
    size = const RelativeSize(width: 0.2, height: 0.2);
    text = labelText;
    textPos = pos;
  }

  @override
  bool get showLabel => _showLabel;

  /// Keyed: `AssetStack` puts a transparent `ColoredBox` of its own in the
  /// tree, so finding the glyph by type is ambiguous.
  static const glyphKey = ValueKey<String>('label-visibility-glyph');

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(key: glyphKey, color: Color(0xFF00AA00));

  @override
  Widget configure(BuildContext context) => const SizedBox.shrink();

  @override
  Map<String, dynamic> toJson() => {
        constAssetName: 'LabelVisibilityTestAsset',
        'x': coordinates.x,
        'y': coordinates.y,
      };
}

Widget _wrap(List<Asset> assets) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: LayoutBuilder(
                builder: (context, constraints) => AssetStack(
                  assets: assets,
                  constraints: constraints,
                  selectedAssets: const {},
                  mirroringDisabled: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('AssetStack consumes Asset.showLabel', () {
    testWidgets('the default paints the label', (tester) async {
      await tester.pumpWidget(
          _wrap([_LabelVisibilityTestAsset(labelText: 'Before freezers')]));
      await tester.pump();
      expect(find.text('Before freezers'), findsOneWidget);
    });

    testWidgets('showLabel false paints no label', (tester) async {
      await tester.pumpWidget(_wrap([
        _LabelVisibilityTestAsset(
            labelText: 'Before freezers', showLabel: false),
      ]));
      await tester.pump();
      expect(find.text('Before freezers'), findsNothing);
    });

    testWidgets('a hidden label leaves the asset where an unnamed one sits',
        (tester) async {
      // The label's measured size feeds the layout, so a hidden caption that
      // was still measured would shove the glyph off the spot the page editor
      // put it on.
      await tester.pumpWidget(_wrap([
        _LabelVisibilityTestAsset(
            labelText: 'A caption long enough to move things',
            showLabel: false),
      ]));
      await tester.pump();
      final hidden =
          tester.getCenter(find.byKey(_LabelVisibilityTestAsset.glyphKey));

      await tester.pumpWidget(_wrap([
        _LabelVisibilityTestAsset(labelText: ''),
      ]));
      await tester.pump();
      expect(tester.getCenter(find.byKey(_LabelVisibilityTestAsset.glyphKey)),
          hidden);
    });
  });
}

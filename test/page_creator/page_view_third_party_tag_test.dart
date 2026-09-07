// End-to-end contract for `ThirdPartyEquipmentConfig.showTag` through the
// real page renderer.
//
// `AssetStack` scales the label font with the asset's bounding box, and the
// third-party machines are big — a SpeedBatcher tag came out huge on the
// mimic. The fix gates the `text` alias on `showTag` (default off), while the
// side pane keeps titling itself from `tag` directly.
//
// Contract under test:
//   - showTag == false (the default): AssetStack paints NO label for the tag.
//   - showTag == true: the tag is painted, restoring the old behaviour.
//
// The pane side of the story is covered in
// `assets/third_party_widget_test.dart` ("tap opens a read-only pane"), which
// asserts the tag reaches the pane title while `text` stays null.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/third_party.dart';
import 'package:tfc/pages/page_view.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

Widget _wrap({required List<Asset> assets}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
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
}

/// A SpeedBatcher with a tag and no run key, so no StateMan is needed —
/// `_hoistStream` leaves the stream null for an empty key.
ThirdPartyEquipmentConfig _speedBatcher({required bool showTag}) =>
    ThirdPartyEquipmentConfig(
      kind: ThirdPartyEquipmentKind.speedBatcher,
      tag: 'SB-01',
      showTag: showTag,
    )
      ..coordinates = Coordinates(x: 0.5, y: 0.5)
      ..size = const RelativeSize(width: 0.4, height: 0.6);

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('ThirdPartyEquipmentConfig.showTag on the page', () {
    testWidgets('hidden by default — the page paints no tag label',
        (tester) async {
      await tester.pumpWidget(_wrap(assets: [_speedBatcher(showTag: false)]));
      await tester.pump();

      expect(find.text('SB-01'), findsNothing,
          reason: 'With showTag off, AssetStack must not paint the tag — '
              'the label scales with the asset box and comes out huge.');
    });

    testWidgets('opting in paints the tag label', (tester) async {
      await tester.pumpWidget(_wrap(assets: [_speedBatcher(showTag: true)]));
      await tester.pump();

      expect(find.text('SB-01'), findsOneWidget);
    });
  });
}

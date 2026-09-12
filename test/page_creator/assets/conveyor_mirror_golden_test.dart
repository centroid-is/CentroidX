import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/conveyor.dart';
import 'package:tfc/pages/page_view.dart';
import '../../helpers/golden_platform.dart';

const _key = Key('conveyor_mirror_test');
const _background = Color(0xFF1A1A2E);

/// The page as a station shows it: a turned conveyor off-centre on an
/// `AssetStack`, so a mirror moves it to the other side AND flips the bend.
Widget _stackScenario() {
  final conveyor = ConveyorConfig.preview()
    ..coordinates = Coordinates(x: 0.38, y: 0.5)
    ..size = const RelativeSize(width: 0.55, height: 0.55)
    ..beltThickness = 0.15
    ..turns.add(ConveyorTurnEntry(position: 0.5, angle: 90, radius: 1.5));
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        backgroundColor: _background,
        body: Center(
          child: RepaintBoundary(
            key: _key,
            child: Container(
              width: 400,
              height: 300,
              color: _background,
              child: LayoutBuilder(
                builder: (context, constraints) => AssetStack(
                  assets: [conveyor],
                  constraints: constraints,
                  selectedAssets: const {},
                  mirroringDisabled: false,
                  absorb: true,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _seedPrefs({bool xMirror = false, bool yMirror = false}) {
  SharedPreferences.setMockInitialValues({});
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.withData({
    'asset_stack_config': jsonEncode({'xMirror': xMirror, 'yMirror': yMirror}),
  });
}

// The frequency figure's readability under the flip is pinned in
// `test/pages/asset_stack_mirror_test.dart` (the painter's counter-mirror
// ops) rather than a golden: the painter's TextStyle names no font family,
// and the test binding renders that as Ahem boxes — mirror-symmetric, so a
// golden of the text cannot show handedness.

void main() {
  group('Conveyor page-mirror golden tests',
      skip: goldenSkip, () {
    testWidgets('turned conveyor, mirroring off (control)', (tester) async {
      _seedPrefs();
      await tester.pumpWidget(_stackScenario());
      await tester.pump();
      await tester.pump();
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_page_mirror_off.png'),
      );
    });

    testWidgets('turned conveyor, x-mirror flips position and bend',
        (tester) async {
      _seedPrefs(xMirror: true);
      await tester.pumpWidget(_stackScenario());
      await tester.pump();
      await tester.pump();
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_page_mirror_x.png'),
      );
    });

    testWidgets('turned conveyor, y-mirror flips position and bend',
        (tester) async {
      _seedPrefs(yMirror: true);
      await tester.pumpWidget(_stackScenario());
      await tester.pump();
      await tester.pump();
      await expectLater(
        find.byKey(_key),
        matchesGoldenFile('goldens/conveyor_turn_page_mirror_y.png'),
      );
    });

  });
}

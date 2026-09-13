/// Goldens for the electrical cabinet asset's rotation support.
///
/// The cabinet is hosted the way `AssetStack` hosts it: a tight box of the
/// asset's unrotated size, centered on a larger dark canvas. Rotation happens
/// inside the asset (`LayoutRotatedBox` reads `coordinates.angle`), so the
/// rotated drawing paints out of the tight box into the surrounding canvas —
/// the goldens capture that overflow.
///
/// To update: flutter test test/page_creator/assets/elcab_golden_test.dart --update-goldens
library;


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/page_creator/assets/common.dart';
import 'package:tfc/page_creator/assets/elcab.dart';
import '../../helpers/golden_platform.dart';

const _boundaryKey = Key('elcab_golden');

Future<void> _pumpCabinet(WidgetTester tester, {double? angle}) async {
  // Empty key: the cabinet renders its closed-door drawing without touching
  // OPC UA, so no StateMan fake is needed.
  final config = ElCabConfig(key: '')
    ..coordinates = Coordinates(x: 0.5, y: 0.5, angle: angle);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF1A1A2E),
          body: Center(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: ColoredBox(
                color: const Color(0xFF1A1A2E),
                child: SizedBox(
                  width: 240,
                  height: 240,
                  child: Center(
                    child: SizedBox(
                      width: 100,
                      height: 140,
                      child: Builder(builder: config.build),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Electrical cabinet golden tests',
      skip: goldenSkip, () {
    testWidgets('no angle renders exactly as before', (tester) async {
      await _pumpCabinet(tester);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/elcab/unrotated.png'),
      );
    });

    testWidgets('45 degrees rotates clockwise inside the asset',
        (tester) async {
      await _pumpCabinet(tester, angle: 45);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/elcab/rotated_45.png'),
      );
    });

    testWidgets('90 degrees lays the cabinet on its side', (tester) async {
      await _pumpCabinet(tester, angle: 90);
      await expectLater(
        find.byKey(_boundaryKey),
        matchesGoldenFile('goldens/elcab/rotated_90.png'),
      );
    });
  });
}

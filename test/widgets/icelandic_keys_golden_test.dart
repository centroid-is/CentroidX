/// What the Icelandic key bar looks like over a focused field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/theme.dart';
import 'package:tfc/widgets/icelandic_keys.dart';

import '../helpers/golden_fonts.dart';
import '../helpers/golden_platform.dart';

Widget harness(Brightness brightness) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: brightness == Brightness.dark ? muted().$2 : muted().$1,
    home: Scaffold(
      body: Stack(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 80, 24, 0),
            child: TextField(
              key: ValueKey('field'),
              decoration: InputDecoration(labelText: 'Heiti'),
            ),
          ),
          const IcelandicKeyBar(),
        ],
      ),
    ),
  );
}

void main() {
  setUpAll(loadGoldenFonts);

  group('icelandic key bar', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('over a focused field ($name)', (tester) async {
        tester.view.physicalSize = const Size(620, 200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(harness(brightness));
        await tester.tap(find.byKey(const ValueKey('field')));
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/icelandic_keys_$name.png'),
        );
      }, skip: goldenSkipFlag);
    }

    testWidgets('shifted to upper case', (tester) async {
      tester.view.physicalSize = const Size(620, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(harness(Brightness.light));
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('icelandic-key-shift')));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/icelandic_keys_shifted.png'),
      );
    }, skip: goldenSkipFlag);
  });
}

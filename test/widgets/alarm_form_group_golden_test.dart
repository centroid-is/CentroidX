import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/alarm.dart';
import 'package:tfc_dart/core/alarm.dart';
import '../helpers/golden_platform.dart';

/// Text in a golden needs a real font, or every glyph is an Ahem box.
///
/// It has to be registered under `roboto-mono` as well as `Roboto`: the muted
/// theme sets `fontFamily: 'roboto-mono'`, so registering only the default
/// family leaves every themed `Text` unresolved and boxed.
Future<void> loadRealFont() async {
  final data = File('lib/fonts/roboto-mono/RobotoMono-Regular.ttf')
      .readAsBytesSync()
      .buffer
      .asByteData();
  for (final family in ['Roboto', 'roboto-mono']) {
    await (FontLoader(family)..addFont(Future.value(data))).load();
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final iconFont = File(
      '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (flutterRoot != null && iconFont.existsSync()) {
    await (FontLoader('MaterialIcons')
          ..addFont(Future.value(iconFont.readAsBytesSync().buffer.asByteData())))
        .load();
  }
}

AlarmConfig alarmWith({
  required List<String> group,
  bool bindToGroup = false,
}) =>
    AlarmConfig(
      uid: 'uid-1',
      title: 'Film reel empty',
      description: 'The upper film reel ran out and the machine stopped.',
      group: group,
      bindToGroup: bindToGroup,
      // No rules: the golden is of the grouping controls, and the rule
      // editor below them is an unrelated widget that overflows at this
      // width on its own.
      rules: const [],
    );

/// The form's identity fields plus the two grouping controls, on the muted
/// theme the plant actually runs.
Widget harness(AlarmConfig config, Brightness brightness) {
  return ProviderScope(
    overrides: [
      alarmManProvider.overrideWith((ref) => Completer<AlarmMan>().future),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.dark ? muted().$2 : muted().$1,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 560,
            child: AlarmForm(
              initialConfig: config,
              editable: true,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('alarm form grouping controls', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('grouped alarm ($name)', (tester) async {
        await loadRealFont();
        tester.view.physicalSize = const Size(620, 620);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(
            harness(alarmWith(group: ['Line 3', 'Multivac']), brightness));
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(AlarmForm),
          matchesGoldenFile('goldens/alarm_form_group_$name.png'),
        );
      }, skip: goldenSkipFlag);

      testWidgets('alarm bound to its group ($name)', (tester) async {
        await loadRealFont();
        tester.view.physicalSize = const Size(620, 620);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(harness(
            alarmWith(group: ['Line 3', 'Afak'], bindToGroup: true),
            brightness));
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(AlarmForm),
          matchesGoldenFile('goldens/alarm_form_group_bound_$name.png'),
        );
      }, skip: goldenSkipFlag);
    }

    testWidgets('ungrouped alarm disables the bind switch', (tester) async {
      await loadRealFont();
      tester.view.physicalSize = const Size(620, 620);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
          harness(alarmWith(group: const []), Brightness.light));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(AlarmForm),
        matchesGoldenFile('goldens/alarm_form_group_ungrouped.png'),
      );
    }, skip: goldenSkipFlag);
  });
}

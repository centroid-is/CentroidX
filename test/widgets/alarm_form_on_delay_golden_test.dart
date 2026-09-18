import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/theme.dart';
import 'package:tfc/widgets/alarm.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';
import '../helpers/golden_platform.dart';
import 'alarm_form_group_golden_test.dart' show loadRealFont;

/// The alarm form with one rule carrying an "Active after" delay, on the
/// muted theme. Captured at the Scaffold so the dark theme's background is in
/// the image.
Widget harness(Brightness brightness) {
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
            width: 760,
            child: AlarmForm(
              initialConfig: AlarmConfig(
                uid: 'uid-1',
                title: 'Conveyor jam',
                description: 'The photo-eye at the infeed has been blocked.',
                rules: [
                  AlarmRule(
                    level: AlarmLevel.error,
                    expression: ExpressionConfig(
                        value: Expression(formula: 'CN01.eye == true')),
                    acknowledgeRequired: true,
                    onDelay: const Duration(seconds: 15),
                  ),
                ],
              ),
              editable: true,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('alarm form rule on-delay', () {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      final name = brightness == Brightness.light ? 'light' : 'dark';

      testWidgets('rule active after 15 s ($name)', (tester) async {
        await loadRealFont();
        tester.view.physicalSize = const Size(820, 1400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(harness(brightness));
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/alarm_form_on_delay_$name.png'),
        );
      }, skip: goldenSkipFlag);
    }
  });
}

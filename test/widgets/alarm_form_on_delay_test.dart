/// The per-rule "Active after" field on the alarm form: how long the rule's
/// expression must hold before the alarm goes active. The backend does the
/// timing; the form only has to carry the value into the saved rule.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/providers/alarm.dart';
import 'package:tfc/widgets/alarm.dart';
import 'package:tfc_dart/core/alarm.dart';
import 'package:tfc_dart/core/boolean_expression.dart';

const _fieldKey = ValueKey('alarm-form-rule-0-on-delay');

AlarmConfig _config({Duration onDelay = Duration.zero}) => AlarmConfig(
      uid: 'uid-1',
      title: 'Conveyor jam',
      description: 'The photo-eye has been blocked',
      rules: [
        AlarmRule(
          level: AlarmLevel.error,
          expression: ExpressionConfig(value: Expression(formula: 'a > 1')),
          acknowledgeRequired: true,
          onDelay: onDelay,
        ),
      ],
    );

Future<void> _pumpForm(WidgetTester tester, AlarmConfig config,
    {bool editable = true, void Function(AlarmConfig)? onSubmit}) async {
  tester.view.physicalSize = const Size(1000, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        alarmManProvider.overrideWith((ref) => Completer<AlarmMan>().future),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: AlarmForm(
            initialConfig: config,
            editable: editable,
            submitText: 'Save',
            onSubmit: onSubmit,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Save'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pump();
}

String _text(WidgetTester tester) => tester
    .widget<TextField>(find.descendant(
        of: find.byKey(_fieldKey), matching: find.byType(TextField)))
    .controller!
    .text;

void main() {
  testWidgets('a stored delay opens in seconds', (tester) async {
    await _pumpForm(tester, _config(onDelay: const Duration(seconds: 15)));
    expect(_text(tester), '15');
  });

  testWidgets('a rule with no delay opens as 0', (tester) async {
    await _pumpForm(tester, _config());
    expect(_text(tester), '0');
  });

  testWidgets('typing seconds saves the delay, keeping the rest of the rule',
      (tester) async {
    AlarmConfig? submitted;
    await _pumpForm(tester, _config(), onSubmit: (c) => submitted = c);

    await tester.enterText(find.byKey(_fieldKey), '2.5');
    await tester.pump();
    await _save(tester);

    final rule = submitted!.rules.single;
    expect(rule.onDelay, const Duration(milliseconds: 2500));
    expect(rule.acknowledgeRequired, isTrue);
    expect(rule.level, AlarmLevel.error);
  });

  testWidgets('editing another rule field keeps the delay', (tester) async {
    AlarmConfig? submitted;
    await _pumpForm(tester, _config(onDelay: const Duration(seconds: 15)),
        onSubmit: (c) => submitted = c);

    await tester.tap(find.text('Acknowledge Required'));
    await tester.pump();
    await _save(tester);

    expect(submitted!.rules.single.onDelay, const Duration(seconds: 15));
    expect(submitted!.rules.single.acknowledgeRequired, isFalse);
  });

  testWidgets('a negative or non-numeric delay blocks the save',
      (tester) async {
    for (final bad in ['-1', 'abc']) {
      AlarmConfig? submitted;
      await _pumpForm(tester, _config(), onSubmit: (c) => submitted = c);

      await tester.enterText(find.byKey(_fieldKey), bad);
      await tester.pump();
      await _save(tester);
      await tester.pump();

      expect(submitted, isNull, reason: '"$bad" is not a delay');
      expect(find.text('Seconds, 0 or more'), findsOneWidget);
    }
  });

  testWidgets('read-only form shows the delay but takes no input',
      (tester) async {
    await _pumpForm(tester, _config(onDelay: const Duration(seconds: 15)),
        editable: false);
    expect(
        tester
            .widget<TextField>(find.descendant(
                of: find.byKey(_fieldKey), matching: find.byType(TextField)))
            .enabled,
        isFalse);
  });
}

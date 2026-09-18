import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open62541/open62541_types.dart' show DynamicValue;

import 'package:tfc/widgets/dynamic_value.dart';

void main() {
  Widget host(DynamicValue v, {ValueChanged<DynamicValue>? onSubmitted}) =>
      MaterialApp(
        home: Scaffold(
          body: DynamicValueWidget(value: v, onSubmitted: onSubmitted ?? (_) {}),
        ),
      );

  DynamicValue str(String s) => DynamicValue(value: s);

  testWidgets('the controller survives a rebuild: typed text and selection '
      'stay put when the PLC value ticks in underneath', (tester) async {
    await tester.pumpWidget(host(str('abc')));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hello');
    final before = tester.widget<TextField>(find.byType(TextField)).controller;

    // Select all, then let a PLC tick rebuild the widget with a new value.
    before!.selection =
        const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pumpWidget(host(str('from-plc')));
    await tester.pump();

    final after = tester.widget<TextField>(find.byType(TextField)).controller;
    expect(identical(before, after), isTrue, reason: 'same controller');
    expect(after!.text, 'hello',
        reason: 'the PLC echo must not clobber what is being typed');
    expect(after.selection.extentOffset - after.selection.baseOffset, 5,
        reason: 'select-all survives the rebuild');
  });

  testWidgets('not editing: the field follows the PLC value', (tester) async {
    await tester.pumpWidget(host(str('abc')));
    await tester.pumpWidget(host(str('def')));
    await tester.pump();
    expect(find.text('def'), findsOneWidget);
  });
}

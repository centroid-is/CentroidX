/// Escape takes down the on-screen keyboard the flutter-elinux panels raise
/// whenever a text field is focused.
///
/// `tester.testTextInput.isVisible` is the framework's stand-in for the
/// platform keyboard: it follows the `TextInput.show` / `TextInput.hide`
/// messages that the elinux embedder turns into show/dismiss of weston's
/// input panel.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/widgets/onscreen_keyboard.dart';
import 'package:tfc/widgets/panes/pane_chrome.dart';
import 'package:tfc/widgets/panes/side_pane.dart';
import 'package:tfc/widgets/panes/standard_dialog.dart';

void main() {
  tearDown(() {
    closeSidePane();
    for (final id in FloatingDialogs.openIds) {
      closeFloatingDialog(id);
    }
    resetEscapeDecisionForTest();
  });

  Widget host({Widget? body}) {
    return OnscreenKeyboardEscape(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const TextField(key: ValueKey('field')),
              Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showSidePane(
                    context: context,
                    id: 'pane',
                    builder: (_) => const SidePane(
                      title: 'CN-04',
                      child: PaneSection(
                        title: 'Setpoints',
                        child: TextField(key: ValueKey('pane-field')),
                      ),
                    ),
                  ),
                  child: const Text('open pane'),
                ),
              ),
              if (body != null) body,
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('Escape takes the keyboard down and drops focus',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isFalse);
    expect(focusedTextField(), isNull);
  });

  testWidgets('Escape with no field focused leaves the keyboard alone',
      (tester) async {
    await tester.pumpWidget(host());
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('Escape closes the keyboard first, then the pane',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('open pane'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pane-field')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse,
        reason: 'the first Escape puts the keyboard away');
    expect(find.byType(SidePane), findsOneWidget,
        reason: '...and leaves the half-typed setpoint where it is');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsNothing);
  });

  testWidgets('Escape closes the keyboard first, then the floating dialog',
      (tester) async {
    await tester.pumpWidget(host(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => showFloatingDialog(
            context: context,
            id: 'dialog',
            title: 'Trend',
            builder: (_) => const TextField(key: ValueKey('dialog-field')),
          ),
          child: const Text('open dialog'),
        ),
      ),
    ));
    await tester.tap(find.text('open dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dialog-field')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(FloatingDialogs.openIds, contains('dialog'));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FloatingDialogs.openIds, isEmpty);
  });

  testWidgets('every handler gets the same answer for one Escape',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    // Whoever asks first decides; the field is unfocused by the time the
    // pane's own handler runs, and it must still be told to sit this one out.
    const event = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.escape,
      logicalKey: LogicalKeyboardKey.escape,
      timeStamp: Duration.zero,
    );
    expect(escapeDismissesKeyboard(event), isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(focusedTextField(), isNull);
    expect(escapeDismissesKeyboard(event), isTrue);
  });
}

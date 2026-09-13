/// The Icelandic key bar types into the focused field, and only then.
///
/// The letters it carries are the ones weston's VNC backend drops before they
/// reach the embedder, so there is no key event to simulate here — tapping is
/// the whole input path, which is what these tests exercise.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/widgets/icelandic_keys.dart';

void main() {
  /// The bar over a page with two fields, laid out the way `main.dart` mounts
  /// it: last in a Stack, above everything that can hold a field.
  Widget host({
    TextEditingController? controller,
    List<TextInputFormatter>? formatters,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Column(
              children: [
                // Clear of the bar, which pins itself to the top: a tap on a
                // field underneath it would land on the bar instead.
                const SizedBox(height: 80),
                TextField(
                  key: const ValueKey('field'),
                  controller: controller,
                  inputFormatters: formatters,
                ),
                const TextField(key: ValueKey('other')),
                const Text('not a field'),
              ],
            ),
            const IcelandicKeyBar(),
          ],
        ),
      ),
    );
  }

  Finder key(String letter) => find.byKey(ValueKey('icelandic-key-$letter'));
  final shift = find.byKey(const ValueKey('icelandic-key-shift'));

  testWidgets('stays hidden until a text field takes focus', (tester) async {
    await tester.pumpWidget(host());
    expect(key('á'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    expect(key('á'), findsOneWidget);

    for (final letter in kIcelandicLetters) {
      expect(key(letter), findsOneWidget, reason: '$letter should be on the bar');
    }
  });

  testWidgets('goes away again when the field loses focus', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    expect(key('þ'), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(key('þ'), findsNothing);
  });

  testWidgets('a tap types the letter into the focused field', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(controller: controller));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    await tester.tap(key('þ'));
    await tester.pumpAndSettle();
    await tester.tap(key('ö'));
    await tester.pumpAndSettle();

    expect(controller.text, 'þö');
    expect(controller.selection.baseOffset, 2);
  });

  testWidgets('typing does not take focus off the field', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;

    await tester.tap(key('æ'));
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(key('æ'), findsOneWidget);
  });

  testWidgets('the letter lands at the caret, not at the end', (tester) async {
    final controller = TextEditingController(text: 'strr');
    await tester.pumpWidget(host(controller: controller));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pumpAndSettle();
    await tester.tap(key('æ'));
    await tester.pumpAndSettle();

    expect(controller.text, 'sætrr');
    expect(controller.selection.baseOffset, 2);
  });

  testWidgets('the letter replaces a selection', (tester) async {
    final controller = TextEditingController(text: 'foXXbar');
    await tester.pumpWidget(host(controller: controller));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    controller.selection = const TextSelection(baseOffset: 2, extentOffset: 4);
    await tester.pumpAndSettle();
    await tester.tap(key('ð'));
    await tester.pumpAndSettle();

    expect(controller.text, 'foðbar');
    expect(controller.selection.baseOffset, 3);
  });

  testWidgets('shift latches for one letter, then releases', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(controller: controller));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    await tester.tap(shift);
    await tester.pumpAndSettle();
    // The bar relabels itself, so the upper-case key is the one to tap.
    expect(key('Á'), findsOneWidget);
    expect(key('á'), findsNothing);

    await tester.tap(key('Á'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Á');

    expect(key('á'), findsOneWidget, reason: 'shift releases after one letter');
    await tester.tap(key('á'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Áá');
  });

  testWidgets('shift can be tapped off again without typing', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    await tester.tap(shift);
    await tester.pumpAndSettle();
    expect(key('Ö'), findsOneWidget);

    await tester.tap(shift);
    await tester.pumpAndSettle();
    expect(key('ö'), findsOneWidget);
  });

  testWidgets('shift does not carry across to the next field', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();
    await tester.tap(shift);
    await tester.pumpAndSettle();
    expect(key('Þ'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('other')));
    await tester.pumpAndSettle();
    expect(key('þ'), findsOneWidget);
  });

  testWidgets('the field keeps its input formatters', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(
      controller: controller,
      formatters: [LengthLimitingTextInputFormatter(2)],
    ));
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pumpAndSettle();

    for (final letter in ['á', 'ð', 'é']) {
      await tester.tap(key(letter));
      await tester.pumpAndSettle();
    }

    expect(controller.text, 'áð');
  });

  testWidgets('types into a field that has never held the caret',
      (tester) async {
    final controller = TextEditingController(text: 'CN');
    await tester.pumpWidget(host(controller: controller));
    // Focus without a tap, so the field reports an invalid selection.
    await tester.showKeyboard(find.byKey(const ValueKey('field')));
    controller.selection = const TextSelection.collapsed(offset: -1);
    await tester.pumpAndSettle();

    await tester.tap(key('ó'));
    await tester.pumpAndSettle();

    expect(controller.text, 'CNó');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/converter/icon.dart';
import 'package:tfc/widgets/icon_picker.dart';

/// Pumps the picker on a surface big enough to show more than one section.
Future<void> _openPicker(
  WidgetTester tester, {
  IconData? selected,
  VoidCallback? onCleared,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: IconPickerDialog(
        selected: selected,
        onSelected: (_) {},
        onCleared: onCleared,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('icon picker', () {
    testWidgets('opens on the industrial sections', (tester) async {
      await _openPicker(tester);
      // The grid is lazy, so the later sections have to be scrolled to.
      for (final group in industrialIconGroups.keys) {
        await tester.scrollUntilVisible(
          find.text(group.toUpperCase()),
          240,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text(group.toUpperCase()), findsOneWidget,
            reason: '$group section is missing');
      }
    });

    testWidgets('searching by name narrows to the matching glyphs',
        (tester) async {
      await _openPicker(tester);
      await tester.enterText(find.byType(TextField), 'proximity');
      await tester.pump();

      // The grouping collapses to a single ranked list of hits.
      expect(find.text('Sensors'.toUpperCase()), findsNothing);
      expect(find.text('sensor proximity'), findsOneWidget);
    });

    testWidgets('a search that matches nothing says so', (tester) async {
      await _openPicker(tester);
      await tester.enterText(find.byType(TextField), 'zzzznotanicon');
      await tester.pump();
      expect(find.text('No icons found'), findsOneWidget);
    });

    testWidgets('clearing the search restores the sections', (tester) async {
      await _openPicker(tester);
      await tester.enterText(find.byType(TextField), 'proximity');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();
      expect(find.text('Sensors'.toUpperCase()), findsOneWidget);
    });

    testWidgets('tapping a glyph reports it', (tester) async {
      IconData? chosen;
      tester.view.physicalSize = const Size(900, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: IconPickerDialog(onSelected: (icon) => chosen = icon),
        ),
      ));
      await tester.enterText(find.byType(TextField), 'motor circle');
      await tester.pump();
      // By the glyph, not its label: the search field also holds that text.
      await tester.tap(find.byIcon(industrialIcons['motor_circle']!));
      await tester.pump();
      expect(chosen, industrialIcons['motor_circle']);
    });

    testWidgets('the clear action only appears when clearing is allowed',
        (tester) async {
      await _openPicker(tester);
      expect(find.text('Clear icon'), findsNothing);

      var cleared = false;
      await _openPicker(tester, onCleared: () => cleared = true);
      expect(find.text('Clear icon'), findsOneWidget);
      await tester.tap(find.text('Clear icon'));
      await tester.pump();
      expect(cleared, isTrue);
    });
  });

  group('icon picker catalogue', () {
    test('offers no name twice', () {
      final names = [for (final entry in iconPickerEntries) entry.name];
      expect(names.length, names.toSet().length,
          reason: 'the same icon name is offered more than once');
    });

    test('every offered glyph serialises back to the name shown', () {
      const converter = IconDataConverter();
      for (final entry in iconPickerEntries) {
        expect(converter.toJson(entry.icon), entry.name);
      }
    });

    test('the industrial glyphs are not repeated under General', () {
      final general = iconPickerSections
          .firstWhere((section) => section.$1 == 'General')
          .$2;
      for (final entry in general) {
        expect(industrialIcons.containsKey(entry.name), isFalse,
            reason: '${entry.name} is in both its group and General');
      }
    });
  });
}

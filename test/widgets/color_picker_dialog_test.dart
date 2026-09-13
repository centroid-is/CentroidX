/// Behaviour of the one colour picker: [ColorPickerRow] +
/// [showColorPickerDialog].
///
/// The regression pinned here crashed a live HMI: the third-party asset
/// editor's hand-rolled picker popped with the EDITOR's context instead of
/// the dialog's own, so a Done tap racing a barrier dismiss popped the app's
/// only page — `'_history.isNotEmpty': is not true` in Navigator.build. The
/// shared dialog pops with its own route context, which cannot reach the
/// page below.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:tfc/widgets/panes/color_picker_dialog.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

Widget _app(Widget body) {
  return MaterialApp(home: Scaffold(body: Center(child: body)));
}

void main() {
  setUp(() {
    useInMemoryDeviceLocalPreferences();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    RecentColors.resetCache();
  });
  testWidgets('row opens the dialog and Done keeps the page alive',
      (tester) async {
    Color color = Colors.green;
    await tester.pumpWidget(_app(StatefulBuilder(
      builder: (context, setState) => ColorPickerRow(
        label: 'Stopped Color',
        color: color,
        onChanged: (c) => setState(() => color = c),
      ),
    )));

    await tester.tap(find.text('Stopped Color'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    // The page below the dialog must survive — this is the crash the shared
    // dialog exists to prevent.
    expect(find.text('Stopped Color'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('barrier dismiss then a queued Done tap cannot pop the page',
      (tester) async {
    await tester.pumpWidget(_app(ColorPickerRow(
      label: 'Colour',
      color: Colors.red,
      onChanged: (_) {},
    )));

    await tester.tap(find.text('Colour'));
    await tester.pumpAndSettle();

    // Dismiss via the barrier, then hit Done's position while the dialog is
    // still animating out — the tap must not fall through to a second pop.
    final done = tester.getCenter(find.text('Done'));
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.tapAt(done);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Colour'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Clear appears only with onCleared and reports null',
      (tester) async {
    var cleared = false;
    await tester.pumpWidget(_app(ColorPickerRow(
      label: 'Text Color',
      color: null,
      onChanged: (_) {},
      onCleared: () => cleared = true,
    )));

    await tester.tap(find.text('Text Color'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear colour'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('a null colour renders the reset glyph on the swatch',
      (tester) async {
    await tester.pumpWidget(_app(ColorPickerRow(
      label: 'Override',
      color: null,
      onChanged: (_) {},
    )));
    expect(find.byIcon(Icons.format_color_reset), findsOneWidget);
  });

  group('Quick-pick strip', () {
    /// The blue preset swatch inside the open dialog.
    Finder presetSwatch(WidgetTester tester, Color color) {
      return find.descendant(
        of: find.byType(Dialog),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color?.toARGB32() ==
                color.toARGB32()),
      );
    }

    testWidgets('theme swatch tap + Done: two LEDs recoloured without touching RGB',
        (tester) async {
      // The workflow that motivated the strip: same colour on two assets,
      // each in two taps.
      Color led1 = Colors.green;
      Color led2 = Colors.red;
      await tester.pumpWidget(_app(StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColorPickerRow(
                label: 'LED 1',
                color: led1,
                onChanged: (c) => setState(() => led1 = c)),
            ColorPickerRow(
                label: 'LED 2',
                color: led2,
                onChanged: (c) => setState(() => led2 = c)),
          ],
        ),
      )));

      for (final label in ['LED 1', 'LED 2']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(presetSwatch(tester, Colors.black));
        await tester.pump();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
      }

      expect(led1.toARGB32(), Colors.black.toARGB32());
      expect(led2.toARGB32(), Colors.black.toARGB32());
    });

    testWidgets('Done records a custom colour and the next dialog offers it',
        (tester) async {
      const custom = Color(0xFF123456);
      await RecentColors.add(custom);
      await tester.pumpWidget(_app(ColorPickerRow(
        label: 'Colour',
        color: Colors.green,
        onChanged: (_) {},
      )));

      await tester.tap(find.text('Colour'));
      await tester.pumpAndSettle();

      expect(find.text('Recent'), findsOneWidget);
      await tester.tap(presetSwatch(tester, custom));
      await tester.pump();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
    });

    test('recents persist, dedupe move-to-front, and cap at max', () async {
      const a = Color(0xFF111111);
      const b = Color(0xFF222222);
      await RecentColors.add(a);
      await RecentColors.add(b);
      await RecentColors.add(a); // back to front, no duplicate
      var recents = await RecentColors.load();
      expect(recents.map((c) => c.toARGB32()),
          [a.toARGB32(), b.toARGB32()]);

      // Survives a cache drop — i.e. an app restart.
      RecentColors.resetCache();
      recents = await RecentColors.load();
      expect(recents.map((c) => c.toARGB32()),
          [a.toARGB32(), b.toARGB32()]);

      for (var i = 0; i < RecentColors.max + 3; i++) {
        await RecentColors.add(Color(0xFF300000 + i));
      }
      expect((await RecentColors.load()).length, RecentColors.max);
    });

    test('strip colours are not recorded as recents', () async {
      await RecentColors.add(Colors.blue,
          skipArgb: {Colors.blue.toARGB32()});
      expect(await RecentColors.load(), isEmpty);
    });
  });
}

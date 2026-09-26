/// Ctrl/Cmd+S saves the page, exactly like the save FAB.
///
/// The contract pinned here:
///
///  * the shortcut persists the edited page without touching the FAB;
///  * it clears the unsaved-changes indicator (the FAB drops its orange);
///  * a clean page saves too — the FAB never refuses, so neither does S;
///  * a focused text field mutes it, like every other canvas shortcut.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import 'package:tfc/pages/page_view.dart' show AssetStack;

import '../helpers/page_editor_harness.dart';
import '../helpers/test_helpers.dart' show useInMemoryDeviceLocalPreferences;

/// Presses the editor's save shortcut.
Future<void> pressSave(WidgetTester tester) async {
  await tester.sendKeyDownEvent(editorModifier);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
  await tester.sendKeyUpEvent(editorModifier);
  await tester.pumpAndSettle();
}

/// The save FAB's current background — orange means unsaved changes.
Color? saveFabColor(WidgetTester tester) {
  final fab = tester.widget<FloatingActionButton>(
    find.widgetWithIcon(FloatingActionButton, Icons.save),
  );
  return fab.backgroundColor;
}

void main() {
  // `gatewayConfigProvider` decides where this panel's configuration rows
  // come from, and it reads the device-local store to do it — so every
  // provider graph that reaches the page manager, the key repository or the
  // StateMan now needs one open. Without it the provider throws
  // "initDeviceLocalPreferences() must run before
  // createDeviceLocalPreferences()", which is the store saying so rather
  // than anything about the case.
  setUp(useInMemoryDeviceLocalPreferences);

  setUp(setUpEditorEnvironment);

  testWidgets('Ctrl/Cmd+S persists the page', (tester) async {
    final prefs = await pumpEditorWith(tester, [editorBox(0.3, 0.3)]);
    await tapAsset(tester, 0.3, 0.3);
    await pressEditorKey(tester, LogicalKeyboardKey.arrowRight);
    expect(readBackHomeAssets(prefs), isNull,
        reason: 'nothing must reach the preferences before the save');

    await pressSave(tester);

    final canvas = tester.getRect(find.byType(AssetStack)).size;
    final saved = readBackHomeAssets(prefs);
    expect(saved, isNotNull, reason: 'Ctrl/Cmd+S must persist the page');
    expect(coordsOf(saved!.single)['x'],
        closeTo(0.3 + 1 / canvas.width, 1e-9));
  });

  testWidgets('Ctrl/Cmd+S clears the unsaved indicator', (tester) async {
    await pumpEditorWith(tester, [editorBox(0.3, 0.3)]);
    await tapAsset(tester, 0.3, 0.3);
    await pressEditorKey(tester, LogicalKeyboardKey.arrowRight);
    expect(saveFabColor(tester), Colors.orange,
        reason: 'the nudge must mark the page dirty first');

    await pressSave(tester);

    expect(saveFabColor(tester), isNot(Colors.orange),
        reason: 'a saved page must not advertise unsaved changes');
  });

  testWidgets('a clean page saves too', (tester) async {
    // The FAB writes unconditionally; the shortcut is its twin, so pressing
    // it on an untouched page still persists — no selection needed either.
    final prefs = await pumpEditorWith(tester, [editorBox(0.3, 0.3)]);

    await pressSave(tester);

    final saved = readBackHomeAssets(prefs);
    expect(saved, isNotNull);
    expect(coordsOf(saved!.single)['x'], closeTo(0.3, 1e-9));
  });

  testWidgets('a focused text field mutes Ctrl/Cmd+S', (tester) async {
    final prefs = await pumpEditorWith(tester, [editorBox(0.3, 0.3)]);
    await tapAsset(tester, 0.3, 0.3);

    // The config pane's text fields take keyboard focus; while they hold it
    // every canvas shortcut stands down, S included.
    await chooseFromAssetMenu(tester, 0.3, 0.3, 'Edit');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    await pressSave(tester);

    expect(readBackHomeAssets(prefs), isNull,
        reason: 'Ctrl/Cmd+S in a text field must not fire the canvas save');
  });
}

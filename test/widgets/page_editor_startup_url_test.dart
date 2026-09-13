/// The startup-page toggle in the Pages dialog: each station picks which URL
/// the app opens on, stored device-locally (never in the shared pages JSON)
/// and written the moment it is toggled — no editor save involved.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tfc/core/startup_url.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';

import '../helpers/page_editor_harness.dart';
import 'package:tfc/providers/preferences.dart'
    show createDeviceLocalPreferences;

/// Home, an ordinary page, and an (empty) section.
PageManager _manager(FakeEditorPreferences prefs) => PageManager(
      prefs: prefs,
      pages: {
        '/': AssetPage(
          menuItem: const MenuItem(label: 'Home', path: '/', icon: Icons.home),
          assets: [],
          mirroringDisabled: true,
          navigationPriority: 0,
        ),
        '/line': AssetPage(
          menuItem: const MenuItem(
              label: 'Line', path: '/line', icon: Icons.conveyor_belt),
          assets: [],
          mirroringDisabled: true,
          navigationPriority: 1,
        ),
        '/sec': AssetPage(
          menuItem: const MenuItem(
              label: 'Section',
              path: '/sec',
              icon: Icons.folder,
              isSection: true),
          assets: [],
          mirroringDisabled: true,
          navigationPriority: 2,
        ),
      },
    );

Future<void> _pumpEditor(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester
      .pumpWidget(buildEditorUnderTest(_manager(FakeEditorPreferences())));
  await tester.pumpAndSettle();
}

Future<void> _openPages(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_drop_down));
  await tester.pumpAndSettle();
  expect(find.text('Pages'), findsOneWidget);
}

/// The device-local store the editor writes into — the one
/// [setUpEditorEnvironment] seeds through `setDeviceLocalPreferencesForTest`.
/// Since v1.2 plan 01-05 that is the store the factory answers, not the
/// `SharedPreferencesAsync` platform instance beneath it.
Future<String?> _storedStartupUrl() =>
    createDeviceLocalPreferences().getString(startupUrlPrefsKey);

void main() {
  setUp(setUpEditorEnvironment);

  testWidgets('by default the Home row is the startup page', (tester) async {
    await _pumpEditor(tester);
    await _openPages(tester);

    final homeToggle = find.descendant(
      of: find.byKey(const ValueKey('startup-/')),
      matching: find.byIcon(Icons.rocket_launch),
    );
    expect(homeToggle, findsOneWidget,
        reason: 'with nothing stored, / is the startup page');
    expect(find.text('Startup page — this station'), findsNothing,
        reason: 'the default is not called out — only an explicit choice is');
  });

  testWidgets('toggling a page persists device-locally, without a save',
      (tester) async {
    await _pumpEditor(tester);
    await _openPages(tester);

    await tester.tap(find.byKey(const ValueKey('startup-/line')));
    await tester.pumpAndSettle();

    expect(await _storedStartupUrl(), '/line',
        reason: 'written immediately — the editor save button is not part '
            'of this, the pref is not in the shared pages JSON');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('startup-/line')),
        matching: find.byIcon(Icons.rocket_launch),
      ),
      findsOneWidget,
    );
  });

  testWidgets('toggling the startup page again resets to the default',
      (tester) async {
    await _pumpEditor(tester);
    await _openPages(tester);

    await tester.tap(find.byKey(const ValueKey('startup-/line')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('startup-/line')));
    await tester.pumpAndSettle();

    expect(await _storedStartupUrl(), isNull,
        reason: 'the default is cleared, not stored');
  });

  testWidgets('a stored startup URL lights up when the dialog opens',
      (tester) async {
    await createDeviceLocalPreferences().setString(startupUrlPrefsKey, '/line');

    await _pumpEditor(tester);
    await _openPages(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('startup-/line')),
        matching: find.byIcon(Icons.rocket_launch),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('startup-/')),
        matching: find.byIcon(Icons.rocket_launch_outlined),
      ),
      findsOneWidget,
      reason: 'only the chosen page is lit',
    );
    expect(find.text('Startup page — this station'), findsOneWidget);
  });

  testWidgets('sections offer no startup toggle — they do not route',
      (tester) async {
    await _pumpEditor(tester);
    await _openPages(tester);

    expect(find.byKey(const ValueKey('startup-/sec')), findsNothing);
    expect(find.byKey(const ValueKey('startup-/advanced')), findsNothing);
  });
}

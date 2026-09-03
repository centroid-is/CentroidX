/// Reports placement in the Pages dialog: like History View it defaults to
/// living under Advanced and the operator can promote it to the top level,
/// recorded as membership in the shared top-level order — which is what
/// main.dart reads back at startup (`reportsIsTopLevel`).
///
/// The pair is worth testing together: they share one order list and one
/// `movableBuiltinPaths` set, so a bug that promoted both at once, or let
/// one demotion drop the other, would pass either file alone.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/models/menu_item.dart';
import 'package:tfc/page_creator/page.dart';
import 'package:tfc/route_registry.dart';
import 'package:tfc/routes.dart';

import '../helpers/page_editor_harness.dart';

/// The menu shape the app has by default: both movable built-ins nested
/// under Advanced.
void _registerMenuWithBuiltinsInAdvanced() {
  final registry = RouteRegistry();
  registry.menuItems.removeWhere((m) => m.path == '/advanced');
  registry.addMenuItem(const MenuItem(
    label: 'Advanced',
    path: '/advanced',
    icon: Icons.settings,
    children: [
      MenuItem(
          label: 'Reports', path: AppRoutes.reports, icon: Icons.summarize),
      MenuItem(
          label: 'History View',
          path: AppRoutes.historyView,
          icon: Icons.history),
    ],
  ));
}

Future<void> _openPages(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.arrow_drop_down));
  await tester.pumpAndSettle();
  expect(find.text('Pages'), findsOneWidget);
}

Future<void> _saveEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Close'));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.save));
  await tester.pumpAndSettle();
}

Future<List<String>> _storedOrder(prefs) async {
  final stored = await prefs.getString(PageManager.orderStorageKey);
  if (stored == null) return const [];
  return (jsonDecode(stored) as List).cast<String>();
}

void main() {
  setUp(() {
    setUpEditorEnvironment();
    _registerMenuWithBuiltinsInAdvanced();
  });

  testWidgets(
      'Reports starts under Advanced: no top-level row, and the dialog '
      'offers "Move to top level"', (tester) async {
    await pumpEditorWith(tester, []);
    await _openPages(tester);

    expect(find.byKey(const ValueKey('app-item-/reports')), findsNothing);
    expect(find.byKey(const ValueKey('advanced-builtin-/reports')),
        findsOneWidget);
  });

  testWidgets('promoting Reports persists it into the top-level order',
      (tester) async {
    final prefs = await pumpEditorWith(tester, []);
    await _openPages(tester);

    await tester.tap(find.byKey(const ValueKey('promote-builtin-/reports')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-item-/reports')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('advanced-builtin-/reports')), findsNothing);

    await _saveEditor(tester);

    expect(await _storedOrder(prefs), contains(AppRoutes.reports),
        reason: 'promotion must survive a restart via the stored order');
  });

  testWidgets('demoting Reports removes it from the stored order',
      (tester) async {
    final prefs = await pumpEditorWith(tester, []);
    await _openPages(tester);

    // Promote then demote — the round trip an operator would take.
    await tester.tap(find.byKey(const ValueKey('promote-builtin-/reports')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('demote-builtin-/reports')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-item-/reports')), findsNothing);
    expect(find.byKey(const ValueKey('advanced-builtin-/reports')),
        findsOneWidget);

    await _saveEditor(tester);
    expect(await _storedOrder(prefs), isNot(contains(AppRoutes.reports)));
  });

  testWidgets('promoting one movable built-in leaves the other in Advanced',
      (tester) async {
    final prefs = await pumpEditorWith(tester, []);
    await _openPages(tester);

    await tester.tap(find.byKey(const ValueKey('promote-builtin-/reports')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-item-/reports')), findsOneWidget);
    expect(find.byKey(const ValueKey('advanced-builtin-/history-view')),
        findsOneWidget,
        reason: 'History View must not ride along with Reports');

    await _saveEditor(tester);

    final order = await _storedOrder(prefs);
    expect(order, contains(AppRoutes.reports));
    expect(order, isNot(contains(AppRoutes.historyView)));
  });

  testWidgets('both can sit at the top level at once', (tester) async {
    final prefs = await pumpEditorWith(tester, []);
    await _openPages(tester);

    await tester.tap(find.byKey(const ValueKey('promote-builtin-/reports')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('promote-builtin-/history-view')));
    await tester.pumpAndSettle();

    await _saveEditor(tester);

    final order = await _storedOrder(prefs);
    expect(order, containsAll([AppRoutes.reports, AppRoutes.historyView]));
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/pages/access_users_section.dart';

/// Opens [username]'s "…" actions menu on the users section.
Future<void> openUserActions(WidgetTester tester, String username) async {
  await tester.tap(find.byKey(kAccessUserActionsKey(username)));
  await tester.pumpAndSettle();
}

/// Opens [username]'s actions menu and taps the entry [action] keys.
///
/// Leaves the frame unpumped after the tap, like a bare `tester.tap`, so the
/// caller's own `pumpAndSettle` is what runs the dialog in.
Future<void> tapUserAction(
  WidgetTester tester,
  Key Function(String username) action,
  String username,
) async {
  await openUserActions(tester, username);
  await tester.tap(find.byKey(action(username)));
}

/// The faded current-value text on [username]'s open menu entry [action].
String? userActionValue(
  WidgetTester tester,
  Key Function(String username) action,
  String username,
) {
  final texts = tester
      .widgetList<Text>(find.descendant(
        of: find.byKey(action(username)),
        matching: find.byType(Text),
      ))
      .toList();
  // The label first, the value (when the entry has one) second.
  return texts.length < 2 ? null : texts[1].data;
}

/// Closes an open menu without choosing anything.
Future<void> dismissUserActions(WidgetTester tester) async {
  await tester.tapAt(Offset.zero);
  await tester.pumpAndSettle();
}

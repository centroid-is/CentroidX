import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

/// The password field inside the expanded OPC-UA card.
Finder _passwordField() => find.widgetWithText(TextField, 'Password (optional)');

/// The helper line that only renders while the card still holds a saved
/// password — its presence after an edit proves the password survived the
/// rebuild of [OpcUAConfig], without the test ever seeing the secret.
Finder _savedMarker() => find.text('Saved — leave blank to keep it');

StateManConfig _configWithPassword() => StateManConfig(
      opcua: [
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.0.0.1:4840'
          ..serverAlias = 'plc1'
          ..username = 'operator'
          ..password = 'correct horse battery staple',
      ],
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  Future<void> pumpExpandedCard(WidgetTester tester) async {
    await pumpAndLoad(
      tester,
      buildTestableServerConfig(stateManConfig: _configWithPassword()),
    );
    await tester.tap(find.text('plc1'));
    await settle(tester);
  }

  group('server password field', () {
    testWidgets('a stored password never enters the text field',
        (tester) async {
      await pumpExpandedCard(tester);

      final field = tester.widget<TextField>(_passwordField());
      // An empty controller is the whole fix: an obscured field pre-filled
      // with the secret would count out its length in dots.
      expect(field.controller!.text, isEmpty);
      expect(_savedMarker(), findsOneWidget);
    });

    testWidgets('editing another field keeps the stored password',
        (tester) async {
      await pumpExpandedCard(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'Endpoint URL'),
          'opc.tcp://10.0.0.9:4840');
      await settle(tester);

      expect(_savedMarker(), findsOneWidget);
    });

    testWidgets('typing replaces the stored password', (tester) async {
      await pumpExpandedCard(tester);

      await tester.enterText(_passwordField(), 'new-secret');
      await settle(tester);

      expect(_savedMarker(), findsNothing);
      expect(find.text('Save Configuration'), findsAtLeastNWidgets(1));
    });

    testWidgets('the remove button clears the stored password',
        (tester) async {
      await pumpExpandedCard(tester);

      // 17-13's config-target banner sits above the sections, and on the
      // default 800x600 test surface it pushed this button just below the
      // fold — scroll it back into the hit-testable area before tapping.
      await tester.ensureVisible(find.byTooltip('Remove password'));
      await settle(tester);
      await tester.tap(find.byTooltip('Remove password'));
      await settle(tester);

      expect(_savedMarker(), findsNothing);
      expect(find.text('Save Configuration'), findsAtLeastNWidgets(1));
    });
  });
}

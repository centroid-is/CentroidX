/// Characterisation of the direct page's save behaviour, pinned BEFORE the
/// editor extraction (quick/20260908-unify-config-ui phase 2) so the move is
/// a refactor with a witness rather than a rewrite:
///
///  * a Modbus host edit reaches the station preferences when saved;
///  * the save button face returns to "All Changes Saved" afterwards —
///    the save button is the page's one unsaved indicator.
///
/// These arms must pass byte-identically on both sides of the extraction.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import 'package:tfc/pages/server_config.dart';
import 'package:tfc/providers/preferences.dart';

import '../helpers/test_helpers.dart';

/// Reads the config back out of preferences, as saved.
Future<StateManConfig> _persistedConfig(WidgetTester tester) async {
  final container =
      ProviderScope.containerOf(tester.element(find.byType(ServerConfigBody)));
  final prefs = await container.read(preferencesProvider.future);
  return StateManConfig.fromPrefs(prefs);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  testWidgets('a saved Modbus host edit lands in the station preferences',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAndLoad(
        tester,
        buildTestableServerConfig(
            stateManConfig: sampleModbusStateManConfig()));

    // Expand the Modbus card and edit its host.
    await tester.scrollUntilVisible(
      find.text('Modbus TCP Servers'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    await tester.tap(find.text('plc_1'));
    await settle(tester);

    await tester.scrollUntilVisible(
      find.widgetWithText(TextField, 'Host'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Host'), '10.0.0.9');
    await settle(tester);

    // Save through the button — the page's one unsaved indicator.
    await tester.scrollUntilVisible(
      find.text('Save Configuration').first,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    await tester.tap(find.text('Save Configuration').first);
    await settle(tester);

    final persisted = await _persistedConfig(tester);
    expect(persisted.modbus.single.host, '10.0.0.9',
        reason: 'the edit must be in the stored document after save');

    // The face returns to saved: no enabled Save Configuration remains.
    expect(find.text('Save Configuration'), findsNothing);
    expect(find.text('All Changes Saved'), findsAtLeastNWidgets(1));
  });
}

/// Characterisation of the direct page's save behaviour, pinned BEFORE the
/// editor extraction (quick/20260908-unify-config-ui phase 2) so the move is
/// a refactor with a witness rather than a rewrite:
///
///  * a Modbus host edit reaches the station preferences when saved;
///  * the save button face returns to "All Changes Saved" afterwards —
///    the save button is the page's one unsaved indicator.
///
/// Those arms pass byte-identically on both sides of the extraction. The
/// second group pins what the extraction ADDED — one document, one save:
///
///  * edits in two different sections are persisted by ONE save (the old
///    page's three private copies made this impossible: section B's save
///    clobbered section A's unsaved edits with A's load-time state);
///  * unknown keys in the stored document survive a typed edit and save
///    (the old page's `fromPrefs → toPrefs` round trip silently dropped
///    everything the typed classes do not model).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
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

  group('one document, one save (added by the phase-2 extraction)', () {
    testWidgets('edits in two sections are persisted by ONE save',
        (tester) async {
      // The old page could not do this: each section held its own full
      // StateManConfig copy, so saving one section clobbered the other's
      // unsaved edits with load-time state. This arm is that bug's
      // tombstone.
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pumpAndLoad(
          tester,
          buildTestableServerConfig(
              stateManConfig: sampleStateManConfigWithModbus()));

      // Edit the OPC UA endpoint...
      await tester.tap(find.text('main_server'));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.widgetWithText(TextField, 'Endpoint URL'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Endpoint URL'),
          'opc.tcp://10.104.28.99:4840');
      await settle(tester);

      // ...and, with the OPC UA card still open, edit the Modbus host.
      await tester.scrollUntilVisible(
        find.text('plc_1'),
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
      await tester.enterText(
          find.widgetWithText(TextField, 'Host'), '10.0.0.77');
      await settle(tester);

      // ONE save button, tapped once.
      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      expect(find.text('Save Configuration'), findsOneWidget,
          reason: 'one document holds one dirty flag and one save button');
      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      final persisted = await _persistedConfig(tester);
      expect(persisted.opcua.single.endpoint, 'opc.tcp://10.104.28.99:4840',
          reason: 'the OPC UA edit must survive the Modbus edit\'s save');
      expect(persisted.modbus.single.host, '10.0.0.77');
    });

    testWidgets('unknown keys in the stored document survive a save',
        (tester) async {
      // The stored document carries content this build does not model —
      // per-entry keys, nested structures, a whole top-level section. A
      // save that dropped them would rewrite the station's document into
      // this build's dialect; the ConfigDocument fidelity rule forbids it.
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Preferences.clearSecretCache();
      DatabaseConfig.clearPrefsCache();
      final storage = FakeSecureStorage();
      await storage.write(
        key: StateManConfig.configKey,
        value: jsonEncode({
          'opcua': [
            {
              'endpoint': 'opc.tcp://plc1:4840',
              'server_alias': 'st101',
              'vendor_note': 'kept-verbatim',
            },
          ],
          'modbus': [
            {
              'host': '192.168.1.100',
              'port': 502,
              'unit_id': 1,
              'server_alias': 'plc_1',
              'poll_groups': [
                {'name': 'default', 'interval_ms': 1000},
              ],
            },
          ],
          'collector_hints': {'window': '5m'},
        }),
      );
      final prefs = Preferences(database: null, secureStorage: storage);

      await pumpAndLoad(
          tester,
          buildTestableServerConfig(overrides: [
            preferencesProvider.overrideWith((ref) async => prefs),
          ]));

      // A typed edit in the Modbus section...
      await tester.scrollUntilVisible(
        find.text('plc_1'),
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
      await tester.enterText(
          find.widgetWithText(TextField, 'Host'), '10.0.0.88');
      await settle(tester);

      await tester.scrollUntilVisible(
        find.text('Save Configuration'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      await tester.tap(find.text('Save Configuration'));
      await settle(tester);

      final raw =
          await prefs.getString(StateManConfig.configKey, secret: true);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final opc = (decoded['opcua'] as List).first as Map<String, dynamic>;
      expect(opc['vendor_note'], 'kept-verbatim',
          reason: 'unknown per-entry key must survive the save');
      expect(decoded['collector_hints'], {'window': '5m'},
          reason: 'unknown top-level section must survive the save');
      final modbus =
          (decoded['modbus'] as List).first as Map<String, dynamic>;
      expect(modbus['host'], '10.0.0.88',
          reason: 'and the typed edit itself must have landed');
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/pages/server_config.dart';
import 'package:tfc/widgets/duration_field.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/preferences_local_store.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';

import '../helpers/test_helpers.dart';

Finder _intervalField() =>
    find.widgetWithText(TextField, 'Update interval');
Finder _lifetimeField() =>
    find.widgetWithText(TextField, 'Secure channel lifetime');

String _textOf(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

/// The unit dropdown belonging to one of the two [DurationField]s.
Finder _unitOf(Finder field) => find.descendant(
    of: find.ancestor(of: field, matching: find.byType(DurationField)).first,
    matching: find.byType(DropdownButton<DurationUnit>));

DurationUnit _unitValue(WidgetTester tester, Finder field) =>
    tester.widget<DropdownButton<DurationUnit>>(_unitOf(field)).value!;

/// Opens a unit dropdown and taps [label] in the menu.
Future<void> pickUnit(
    WidgetTester tester, Finder field, String label) async {
  await tester.tap(_unitOf(field));
  await settle(tester);
  // The menu repeats the currently-selected item behind the overlay, so take
  // the last match — the one in the open menu.
  await tester.tap(find.text(label).last);
  await settle(tester);
}

/// Reads the config back out of preferences, as saved.
Future<StateManConfig> _persistedConfig(WidgetTester tester) async {
  final container =
      ProviderScope.containerOf(tester.element(find.byType(ServerConfigBody)));
  final prefs = await container.read(localStorePreferencesProvider.future);
  return StateManConfigStorage.fromPrefs(prefs);
}

StateManConfig _oneServer({int? intervalMs, int? lifetimeMs}) => StateManConfig(
      opcua: [
        OpcUAConfig()
          ..endpoint = 'opc.tcp://10.104.28.11:4840'
          ..serverAlias = 'st101'
          ..publishingIntervalMs = intervalMs ?? 100
          ..secureChannelLifetimeMs = lifetimeMs ?? 600000,
      ],
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  Future<void> pumpExpandedCard(WidgetTester tester,
      {StateManConfig? config}) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpAndLoad(
      tester,
      buildTestableServerConfig(stateManConfig: config ?? _oneServer()),
    );
    await tester.tap(find.text('st101'));
    await settle(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('Save Configuration').first, 200,
        scrollable: find.byType(Scrollable).first);
    await settle(tester);
    await tester.tap(find.text('Save Configuration').first);
    await settle(tester);
  }

  group('OPC-UA timing fields', () {
    testWidgets('an expanded card shows both timing fields', (tester) async {
      await pumpExpandedCard(tester);

      expect(_intervalField(), findsOneWidget);
      expect(_lifetimeField(), findsOneWidget);
    });

    testWidgets('the fields are seeded in the largest unit that fits',
        (tester) async {
      await pumpExpandedCard(
          tester, config: _oneServer(intervalMs: 250, lifetimeMs: 300000));

      // 250 ms does not divide into seconds, so it stays in ms.
      expect(_textOf(tester, _intervalField()), '250');
      expect(_unitValue(tester, _intervalField()), DurationUnit.milliseconds);
      // 300000 ms is exactly five minutes — nobody should read that as 300000.
      expect(_textOf(tester, _lifetimeField()), '5');
      expect(_unitValue(tester, _lifetimeField()), DurationUnit.minutes);
    });

    testWidgets('the 10-minute default reads as 10 min, not 600000',
        (tester) async {
      await pumpExpandedCard(tester);

      expect(_textOf(tester, _lifetimeField()), '10');
      expect(_unitValue(tester, _lifetimeField()), DurationUnit.minutes);
      expect(_textOf(tester, _intervalField()), '100');
      expect(_unitValue(tester, _intervalField()), DurationUnit.milliseconds);
    });

    testWidgets('a value that divides evenly is promoted to the bigger unit',
        (tester) async {
      await pumpExpandedCard(tester, config: _oneServer(intervalMs: 2000));

      expect(_textOf(tester, _intervalField()), '2');
      expect(_unitValue(tester, _intervalField()), DurationUnit.seconds);
    });

    testWidgets('changing the unit keeps the number and changes the duration',
        (tester) async {
      // The move someone makes on realising they picked the wrong unit.
      // Converting instead would show 600 s and make them clear the box.
      await pumpExpandedCard(tester);
      expect(_textOf(tester, _lifetimeField()), '10');

      await pickUnit(tester, _lifetimeField(), 's');
      await save(tester);

      expect(_textOf(tester, _lifetimeField()), '10');
      expect(
          (await _persistedConfig(tester)).opcua.single.secureChannelLifetimeMs,
          10000);
    });

    testWidgets('a unit change that overshoots the max clamps and says so',
        (tester) async {
      await pumpExpandedCard(tester, config: _oneServer(intervalMs: 100));

      // 100 ms is fine; 100 s is twenty times the ceiling.
      await pickUnit(tester, _intervalField(), 's');
      await save(tester);

      expect((await _persistedConfig(tester)).opcua.single.publishingIntervalMs,
          OpcUAConfig.publishingIntervalMaxMs);
      // The box must not keep claiming 100 when 5 s was stored.
      expect(_textOf(tester, _intervalField()), '5');
    });

    testWidgets('a typed interval reaches the saved config', (tester) async {
      await pumpExpandedCard(tester);

      await tester.enterText(_intervalField(), '500');
      await settle(tester);
      await save(tester);

      expect((await _persistedConfig(tester)).opcua.single.publishingIntervalMs,
          500);
    });

    testWidgets('a typed lifetime is saved back in milliseconds',
        (tester) async {
      await pumpExpandedCard(tester);

      // Two minutes, typed as two.
      await tester.enterText(_lifetimeField(), '2');
      await settle(tester);
      await save(tester);

      expect(
          (await _persistedConfig(tester)).opcua.single.secureChannelLifetimeMs,
          120000);
    });

    testWidgets('a fractional value rounds to milliseconds', (tester) async {
      await pumpExpandedCard(tester);

      await pickUnit(tester, _lifetimeField(), 's');
      await tester.enterText(_lifetimeField(), '90.5');
      await settle(tester);
      await save(tester);

      expect(
          (await _persistedConfig(tester)).opcua.single.secureChannelLifetimeMs,
          90500);
    });

    testWidgets('an out-of-range interval is clamped, not stored raw',
        (tester) async {
      await pumpExpandedCard(tester);

      // Well past the heartbeat staleness window — accepted as typed it
      // would make a healthy server report itself unhealthy.
      await tester.enterText(_intervalField(), '600000');
      await settle(tester);
      await save(tester);

      expect((await _persistedConfig(tester)).opcua.single.publishingIntervalMs,
          OpcUAConfig.publishingIntervalMaxMs);
    });

    testWidgets('a zero interval is clamped up to the minimum', (tester) async {
      await pumpExpandedCard(tester);

      await tester.enterText(_intervalField(), '0');
      await settle(tester);
      await save(tester);

      expect((await _persistedConfig(tester)).opcua.single.publishingIntervalMs,
          OpcUAConfig.publishingIntervalMinMs);
    });

    testWidgets('clearing a field keeps the stored value, not zero',
        (tester) async {
      // Mid-typing the box is empty for a frame. Treating that as a number
      // would drop the interval to 0 and the lifetime to nothing.
      await pumpExpandedCard(
          tester, config: _oneServer(intervalMs: 250, lifetimeMs: 300000));

      await tester.enterText(_intervalField(), '');
      await tester.enterText(_lifetimeField(), '');
      await settle(tester);
      // Empty boxes are not themselves a change, so nothing offers to save.
      // Touch another field to force the rebuilt config through with the
      // timing boxes still blank — the shape of the half-typed edit.
      await tester.enterText(
          find.widgetWithText(TextField, 'Endpoint URL'), 'opc.tcp://x:4840');
      await settle(tester);
      await save(tester);

      final saved = (await _persistedConfig(tester)).opcua.single;
      expect(saved.publishingIntervalMs, 250);
      expect(saved.secureChannelLifetimeMs, 300000);
    });

    testWidgets('editing the endpoint does not reset the timing values',
        (tester) async {
      await pumpExpandedCard(
          tester, config: _oneServer(intervalMs: 250, lifetimeMs: 300000));

      await tester.enterText(
          find.widgetWithText(TextField, 'Endpoint URL'), 'opc.tcp://x:4840');
      await settle(tester);
      await save(tester);

      final saved = (await _persistedConfig(tester)).opcua.single;
      expect(saved.endpoint, 'opc.tcp://x:4840');
      expect(saved.publishingIntervalMs, 250);
      expect(saved.secureChannelLifetimeMs, 300000);
    });

    testWidgets('changing a timing value counts as an unsaved change',
        (tester) async {
      await pumpExpandedCard(tester);

      await tester.enterText(_intervalField(), '500');
      await settle(tester);

      expect(find.text('Save Configuration'), findsAtLeastNWidgets(1));
    });
  });
}

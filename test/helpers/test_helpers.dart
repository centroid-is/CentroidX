import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;

import 'package:tfc/providers/access.dart' show stationNameProvider;
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/server_config.dart';

/// The station name every server-config fixture pins — see the override in
/// [buildTestableServerConfig].
const String kTestStationName = 'SVN-ST101';

/// In-memory secure storage for tests.
class FakeSecureStorage implements MySecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<String?> read({required String key}) async {
    return _store[key];
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }
}

/// Creates a test [Preferences] backed by in-memory storage.
///
/// [database] is null by default, which is what almost every test wants. Pass
/// one where the test needs a write to land in a real `flutter_preferences`
/// row — the server-config publish path reads back through
/// `ServerConfigDb.fetch`, which goes to the database rather than the cache.
Future<Preferences> createTestPreferences({
  KeyMappings? keyMappings,
  StateManConfig? stateManConfig,
  Database? database,
}) async {
  // The secret cache is static (process-wide) so stale entries from a
  // previous test would shadow this test's fresh FakeSecureStorage contents.
  Preferences.clearSecretCache();
  DatabaseConfig.clearPrefsCache();
  final secureStorage = FakeSecureStorage();
  final prefs = Preferences(database: database, secureStorage: secureStorage);

  // Pre-populate key_mappings
  final km = keyMappings ?? KeyMappings(nodes: {});
  await prefs.setString('key_mappings', jsonEncode(km.toJson()));

  // Pre-populate state_man_config in secure storage (StateManConfig reads with secret: true)
  final smc = stateManConfig ?? StateManConfig(opcua: []);
  await secureStorage.write(
    key: StateManConfig.configKey,
    value: jsonEncode(smc.toJson()),
  );

  return prefs;
}

/// Creates a sample [KeyMappings] with test data.
KeyMappings sampleKeyMappings() {
  return KeyMappings(nodes: {
    'temperature_sensor': KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Temperature')
        ..serverAlias = 'main_server',
      collect: CollectEntry(
        key: 'temperature_sensor',
        name: 'Temperature',
        sampleInterval: const Duration(microseconds: 1000000),
        retention: const RetentionPolicy(
          dropAfter: Duration(days: 30),
          scheduleInterval: null,
        ),
      ),
    ),
    'pressure_valve': KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 3, identifier: 'PressureValve')
        ..serverAlias = 'main_server',
    ),
  });
}

/// Creates a sample [StateManConfig] with test server aliases.
StateManConfig sampleStateManConfig() {
  return StateManConfig(opcua: [
    OpcUAConfig()
      ..endpoint = 'opc.tcp://localhost:4840'
      ..serverAlias = 'main_server',
    OpcUAConfig()
      ..endpoint = 'opc.tcp://localhost:4841'
      ..serverAlias = 'backup_server',
  ]);
}

/// Wraps the [KeyRepositoryContent] widget in a testable widget tree
/// with [ProviderScope] overrides for [preferencesProvider].
/// The key list's own scrollable.
///
/// The key list builds lazily, so cards outside the viewport do not exist and
/// tests must scroll this to reach them. Text fields contain Scrollables too,
/// but those run horizontally.
///
/// **Identified by its controller, not by being the only one.** It used to be
/// enough to ask for the one downward Scrollable on the page. Two more can now
/// be on screen at once: the whole-page fallback that
/// `KeyRepositoryContent.minContentHeight` engages on a short window — which
/// the access-templates section made reachable at the 800x600 test surface —
/// and the templates list itself. Neither has a `controller`; the key list is
/// built with `_listController` in both its reorderable and its filtered
/// branch, so this predicate names the list rather than counting on there
/// being nothing else that scrolls.
final Finder keyListScrollable = find.byWidgetPredicate((w) =>
    w is Scrollable &&
    w.axisDirection == AxisDirection.down &&
    w.controller != null);

/// Scrolls the key list back to the top so the first cards are built again.
Future<void> scrollKeyListToTop(WidgetTester tester) async {
  tester.state<ScrollableState>(keyListScrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

/// Scrolls down the key list until the card named [name] is built, and
/// asserts it showed up.
Future<void> revealKeyCard(WidgetTester tester, String name) async {
  final finder = find.text(name);
  var guard = 0;
  while (finder.evaluate().isEmpty && guard++ < 30) {
    await tester.drag(keyListScrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  expect(finder, findsAtLeastNWidgets(1),
      reason: 'card "$name" never scrolled into view');
}

Widget buildTestableKeyRepository({
  KeyMappings? keyMappings,
  StateManConfig? stateManConfig,
  StateMan? stateMan,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: keyMappings,
            stateManConfig: stateManConfig,
          )),
      databaseProvider.overrideWith((ref) async => null),
      // 17-12: the access store providers now consult the transport row
      // (`gatewayConfigProvider` → `localPreferencesProvider`) before choosing
      // their route. An in-memory device-local store reads as direct mode and
      // keeps these page tests from reaching an unmocked SharedPreferences.
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      // Override stateManProvider to avoid real network connections.
      // With no [stateMan] given it throws, which the page treats as
      // "nothing to probe".
      stateManProvider.overrideWith((ref) =>
          stateMan ?? (throw StateError('No StateMan in tests'))),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: KeyRepositoryContent(),
      ),
    ),
  );
}

/// Creates a sample [StateManConfig] with one Modbus server for tests.
StateManConfig sampleModbusStateManConfig() {
  return StateManConfig(
    opcua: [],
    modbus: [
      ModbusConfig(
        host: '192.168.1.100',
        port: 502,
        unitId: 1,
        pollGroups: [
          ModbusPollGroupConfig(name: 'default', intervalMs: 1000),
        ],
      )..serverAlias = 'plc_1',
    ],
  );
}

/// Creates a sample [StateManConfig] with one Modbus server that has 2 poll groups.
StateManConfig sampleModbusWithTwoPollGroups() {
  return StateManConfig(
    opcua: [],
    modbus: [
      ModbusConfig(
        host: '192.168.1.100',
        port: 502,
        unitId: 1,
        pollGroups: [
          ModbusPollGroupConfig(name: 'default', intervalMs: 1000),
          ModbusPollGroupConfig(name: 'fast', intervalMs: 100),
        ],
      )..serverAlias = 'plc_1',
    ],
  );
}

/// Creates sample [KeyMappings] with Modbus keys for tests.
KeyMappings sampleModbusKeyMappings() {
  return KeyMappings(nodes: {
    'modbus_temp': KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: 'plc_1',
        registerType: ModbusRegisterType.holdingRegister,
        address: 100,
        dataType: ModbusDataType.float32,
        pollGroup: 'default',
      ),
    ),
    'modbus_coil': KeyMappingEntry(
      modbusNode: ModbusNodeConfig(
        serverAlias: 'plc_1',
        registerType: ModbusRegisterType.coil,
        address: 0,
        dataType: ModbusDataType.bit,
        pollGroup: 'default',
      ),
    ),
  });
}

/// Creates a sample [StateManConfig] with both OPC UA and Modbus servers.
/// Enables testing that Modbus ChoiceChip appears alongside OPC UA.
StateManConfig sampleStateManConfigWithModbus() {
  return StateManConfig(
    opcua: [
      OpcUAConfig()
        ..endpoint = 'opc.tcp://localhost:4840'
        ..serverAlias = 'main_server',
    ],
    modbus: [
      ModbusConfig(
        host: '192.168.1.100',
        port: 502,
        unitId: 1,
        pollGroups: [
          ModbusPollGroupConfig(name: 'default', intervalMs: 1000),
          ModbusPollGroupConfig(name: 'fast', intervalMs: 100),
        ],
      )..serverAlias = 'plc_1',
    ],
  );
}

/// Creates a sample [StateManConfig] with a UMAS-enabled Modbus server.
/// For testing Browse button visibility in key repository.
StateManConfig sampleStateManConfigWithUmas() {
  return StateManConfig(
    opcua: [],
    modbus: [
      ModbusConfig(
        host: '192.168.1.200',
        port: 502,
        unitId: 1,
        umasEnabled: true,
        pollGroups: [
          ModbusPollGroupConfig(name: 'default', intervalMs: 1000),
        ],
      )..serverAlias = 'schneider_plc',
    ],
  );
}

/// Pumps widget and waits for async config loading to complete.
///
/// ServerConfigBody sections show CircularProgressIndicator during async
/// _loadConfig(). The indeterminate animation prevents pumpAndSettle from
/// settling. This helper uses explicit pump() calls to let Futures resolve.
Future<void> pumpAndLoad(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await settle(tester);
}

/// Pumps frames to let async operations and animations advance without
/// requiring all animations to finish (unlike pumpAndSettle).
///
/// Use this instead of pumpAndSettle when the widget tree contains
/// indeterminate animations (e.g. CircularProgressIndicator) that prevent
/// pumpAndSettle from ever returning.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Wraps the [ServerConfigPage] body in a testable widget tree.
///
/// Bypasses [BaseScaffold] (which requires Beamer routing context) by
/// rendering the same Column of sections that [ServerConfigPage.build]
/// produces. This tests all section widgets without needing a full router.
///
/// [localPreferences] is the device-local store the transport-mode card reads
/// and writes. Pass one to seed a station into gateway mode, or to read back
/// what a save wrote; the default is an empty in-memory store, which is a
/// station that has never been configured and therefore runs direct.
///
/// [theme] and [overrides] are **additive and defaulted**, so all thirteen
/// existing callers render byte-identically without being edited. They exist
/// for the themed goldens in plan 15-07: the bare `MaterialApp` below carries
/// no theme at all, which means `HmiStateColors.of(context)` silently falls
/// back to `solarizedLight` and a colour regression on the dark scheme cannot
/// be caught. Pass `themedGoldenTheme(dark: …)` from
/// `test/helpers/themed_golden_host.dart` to shoot this page under the real
/// station themes.
///
/// [overrides] is appended **after** the four above, so a caller can add
/// `gatewayLinkProvider.overrideWith(…)` without restating them — and, because
/// it comes last, can deliberately replace one of them.
Widget buildTestableServerConfig({
  StateManConfig? stateManConfig,
  PreferencesApi? localPreferences,
  ThemeData? theme,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      // 17-13's config-target banner names this station, and the production
      // value is `Platform.localHostname` — a different string on every
      // machine. Pinned here so the page's goldens do not disagree with
      // themselves by machine; a caller that needs another name replaces it
      // through [overrides], which comes last.
      stationNameProvider.overrideWithValue(kTestStationName),
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            stateManConfig: stateManConfig,
          )),
      localPreferencesProvider
          .overrideWithValue(localPreferences ?? InMemoryPreferences()),
      databaseProvider.overrideWith((ref) async => null),
      // Override stateManProvider to avoid real network connections.
      // Throwing makes valueOrNull return null and isLoading false,
      // so connection status shows "Not active" (grey).
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
      ...overrides,
    ],
    child: MaterialApp(
      // Keeps the debug ribbon out of the corner of golden captures.
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: const ServerConfigBody(),
      ),
    ),
  );
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/guarded_config_store.dart';
import 'package:tfc_dart/core/config/config_item.dart';
import 'package:tfc_dart/core/config/config_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/interface.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart'
    show SecureStorage;
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_dart/core/collector.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/modbus_client_wrapper.dart' show ModbusDataType;

import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/config_store.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc/pages/key_repository.dart';
import 'package:tfc/pages/server_config.dart';

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

/// Gives this test a secret store that is not the machine's keychain.
///
/// `SecureStorage.getInstance()` answers a real OS keychain when nothing has
/// been set: libsecret on Linux, the login keychain on macOS, and on Windows
/// it does not answer at all — it throws `SecureStorage instance not set for
/// this platform`. Anything reaching `preferencesProvider` reaches it, because
/// the provider builds a `Preferences` with `SecureStorage.getInstance()`
/// (`providers/preferences.dart:240`), so a test that never mentions a secret
/// still depends on the machine having a keychain. That is why
/// `preferences_provider_test.dart` passed on a developer's Mac and failed on
/// both CI platforms we ship: seven tests on Windows, where the call throws,
/// and one on Linux, where the call succeeds and only the `write` fails for
/// want of `libsecret-1`.
///
/// The substitute is a real store, not a stub: [FakeSecureStorage] keeps what
/// it is given and hands it back. A test asserting that a secret was written,
/// or that it went to the keychain instead of a `config_item` row, still has
/// something to assert against — a fake that swallowed writes would make those
/// claims pass by meaning nothing.
///
/// Call it from `setUp`. A fresh empty store replaces it at teardown, so a
/// secret written by one test is not visible to the next, and no test in this
/// file touches the developer's own keychain either.
FakeSecureStorage useFakeSecureStorage() {
  final storage = FakeSecureStorage();
  SecureStorage.setInstance(storage);
  addTearDown(() => SecureStorage.setInstance(FakeSecureStorage()));
  return storage;
}

/// Gives this test the device-local store that `main()` opens before
/// `runApp`.
///
/// Since milestone v1.2 plan 01-05, `createDeviceLocalPreferences()` answers a
/// process-wide SQLite store opened by `initDeviceLocalPreferences()` and
/// throws a [StateError] when that has not run — deliberately, because a
/// silently empty store at boot is a station that has lost its pages. A test
/// that pumps a widget reaching the factory (any `AssetStack`, the colour
/// picker, the tech-doc library) therefore has to say which store it means,
/// exactly as it already says which `SharedPreferencesAsyncPlatform` it means.
///
/// Call it from `setUp`; the store is cleared again after the test, so no
/// preference written by one test is visible to the next. The store is
/// returned for the tests that need to seed a key into it — the ones that used
/// to hand `InMemorySharedPreferencesAsync.withData(...)` a map.
InMemoryPreferences useInMemoryDeviceLocalPreferences() {
  final store = InMemoryPreferences();
  setDeviceLocalPreferencesForTest(store);
  // The full reset rather than `setDeviceLocalPreferencesForTest(null)`:
  // `deviceLocalDatabase()` lazily opens an in-memory `AppDatabase` beside
  // this store (that is what a station whose `config.sqlite` will not open
  // gets), and clearing the pointer without closing the handle leaks one
  // drift background isolate per test file that reads the config store.
  addTearDown(resetDeviceLocalPreferencesForTest);
  return store;
}

/// A [GuardedConfigStore] over two in-memory databases — the station's mirror
/// and a stand-in for the shared Postgres — for tests that need the shared
/// configuration store without a Postgres.
///
/// Override `configStoreProvider` with it. The key mappings are seeded
/// **through the store's own write path**, so every payload is codec output:
/// a hand-assembled `{"opcua_node": …}` is structurally a different payload
/// (every model class emits its unset optionals as explicit nulls) and the
/// next diff would report the whole plant as rewired.
///
/// The sync engine is left off (`startSync: false`): a test that drives the
/// write path and asserts what it wrote does not want a background reconcile
/// answering for it. Both databases are closed at teardown.
/// A session that holds `configure`, which is the group the policy classes
/// `pref`/`key_mappings` as.
///
/// [createTestConfigStore] defaults to an anonymous operator on purpose — the
/// guard-wiring tests need a refusal — so every test that drives an editor
/// save has to say that somebody who may configure is standing at the panel.
final AccessSession kConfiguringTestSession =
    AccessSession(groups: const {AccessGroup.configure});

Future<GuardedConfigStore> createTestConfigStore({
  KeyMappings? keyMappings,
  AccessPolicy policy = const AccessPolicy(),
  AccessSession? session,
  /// The session read **at each write**, for a test that signs in or out
  /// between two of them.
  ///
  /// [session] freezes one; this one is the shape production uses
  /// (`configStoreProvider` passes `() => sessionInForce(ref)`), and without it
  /// a guard built here can only ever answer with the session it was made
  /// with — which is exactly the elevation window the callback exists to
  /// close. Wins over [session] when both are given.
  AccessSession Function()? sessionOf,
  AuditSink? audit,
  String station = 'test-station',
  void Function(AccessDenied denial)? onDenied,
  /// Whether to attach the stand-in for Postgres at all.
  ///
  /// `false` is a station that booted with the shared database unreachable:
  /// the store serves its mirror and refuses every shared write with
  /// `ConfigStoreOfflineException`. That is the arm C-11 is about, and it has
  /// no other way to be reached in a test.
  bool withRemote = true,
  /// Handed the stand-in remote once it is attached, for a test that has to
  /// go behind the store's back — bumping a row's `rev` the way another
  /// station would, or reading the `config_change` rows a save wrote.
  void Function(AppDatabase remote)? onRemote,
  /// The stand-in for Postgres, when the test already has one.
  ///
  /// `ServerConfigDb.fetch` selects straight out of the shared database the
  /// page was handed, so a test of that round trip needs the store's writes
  /// to land in *that* database rather than in one this helper made up. The
  /// caller owns it and closes it.
  AppDatabase? remoteDatabase,
}) async {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final local = AppDatabase.inMemoryForTest();
  final remote = remoteDatabase ?? AppDatabase.inMemoryForTest();
  addTearDown(local.close);
  if (remoteDatabase == null) addTearDown(remote.close);

  final store = ConfigStore(
    local: local,
    stationScope: ConfigScope.forStation(station),
    station: station,
  );
  addTearDown(store.close);
  await store.open();
  if (withRemote) {
    store.attachRemoteDatabase(remote, startSync: false);
    onRemote?.call(remote);
  }

  final mappings = keyMappings ?? KeyMappings(nodes: {});
  if (mappings.nodes.isNotEmpty && withRemote) {
    await store.writeKeyMappings(mappings,
        actionId: 'test-seed', who: 'test', roleName: 'system');
  }

  return GuardedConfigStore(
    inner: store,
    policy: policy,
    session: sessionOf ??
        () => session ?? AccessSession.anonymous(const {AccessGroup.operate}),
    audit: audit ?? _DiscardingAuditSink(),
    station: station,
    onDenied: onDenied,
  );
}

class _DiscardingAuditSink implements AuditSink {
  @override
  Future<void> record(AuditRecord entry) async {}
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
  GuardedConfigStore? configStore,
  Future<GuardedConfigStore>? configStoreFuture,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: keyMappings,
            stateManConfig: stateManConfig,
          )),
      databaseProvider.overrideWith((ref) async => null),
      // Since v1.2 phase 2 plan 06 the page loads and saves the plant's wiring
      // through the shared configuration store, not the preference blob. A
      // caller that wants to read back what a save wrote builds the store
      // itself with [createTestConfigStore] and passes it here.
      configStoreProvider.overrideWith((ref) =>
          configStore != null
              ? Future<GuardedConfigStore>.value(configStore)
              : configStoreFuture ??
                  createTestConfigStore(
                    keyMappings: keyMappings,
                    session: kConfiguringTestSession,
                  )),
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
Widget buildTestableServerConfig({
  StateManConfig? stateManConfig,
}) {
  return ProviderScope(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            stateManConfig: stateManConfig,
          )),
      databaseProvider.overrideWith((ref) async => null),
      // Override stateManProvider to avoid real network connections.
      // Throwing makes valueOrNull return null and isLoading false,
      // so connection status shows "Not active" (grey).
      stateManProvider
          .overrideWith((ref) => throw StateError('No StateMan in tests')),
    ],
    child: MaterialApp(
      // Keeps the debug ribbon out of the corner of golden captures.
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: const ServerConfigBody(),
      ),
    ),
  );
}

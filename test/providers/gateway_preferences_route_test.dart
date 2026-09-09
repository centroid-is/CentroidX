@TestOn('vm')

/// `preferencesProvider` follows the transport, and — the arm that matters
/// most here — it **builds without a relay client**.
///
/// That second property is not a nicety. `stateManProvider` awaits this
/// provider in order to read `state_man_config` and `key_mappings`, and it is
/// the thing that constructs the client. If this provider waited for the
/// client, the two would wait for each other and the panel would never finish
/// booting — no error, no screen, nothing to read. A deadlock is the one
/// failure mode a slow test machine and a plant look identical for, so it is
/// pinned with a real timeout rather than left to reviewer attention.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/startup_url.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/providers/gateway_preferences_slot.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

/// The backend's store, as the wire sees it.
final class _Backend implements rp.PreferencesApi {
  final Map<String, Object?> store = {};
  final _changes = StreamController<String>.broadcast();

  @override
  Future<String?> getString(String key) async => store[key] as String?;
  @override
  Future<void> setString(String key, String value) async => store[key] = value;
  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'no arm here should need ${invocation.memberName}');
}

const _gateway = GatewayConfig(
  mode: TransportMode.gateway,
  url: 'wss://gateway.svn:9443',
  caCertPath: '/etc/tfc/ca.pem',
);

/// [holdStateMan] parks `stateManProvider` instead of letting the real one
/// build.
///
/// The real one dials a gateway that is not there, fails, and calls
/// `prefsSlot.fail` — which would race the manual `fill` the arms below do and
/// make them flaky rather than wrong. The one arm that must NOT hold it is the
/// deadlock arm, whose whole claim is that `preferencesProvider` finishes with
/// the real `stateManProvider` free to be as slow as it likes.
ProviderContainer _container({
  required GatewayConfig gateway,
  bool holdStateMan = false,
}) {
  final container = ProviderContainer(overrides: [
    gatewayConfigProvider.overrideWith((ref) async => gateway),
    if (holdStateMan)
      stateManProvider.overrideWith((ref) => Completer<StateMan>().future),
    // 17-12's technique: in gateway mode the database dependency must not
    // merely go unused, it must not be reachable. A provider that still
    // watched this would pull the station's Postgres pool up at boot, which
    // is the dependency the rig measured and this transport is supposed to
    // have shed.
    databaseProvider.overrideWith((ref) async =>
        throw StateError('databaseProvider must not be read in gateway mode')),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    DatabaseConfig.clearPrefsCache();
  });

  test('it builds in gateway mode with no relay client, and does not touch '
      'the database on the way', () async {
    final container = _container(gateway: _gateway);

    // The deadlock guard. `stateManProvider` — the only thing that can fill
    // the slot — is not built here at all, so this must complete against an
    // empty slot or not at all.
    final prefs = await container
        .read(preferencesProvider.future)
        .timeout(const Duration(seconds: 5),
            onTimeout: () => fail(
                'preferencesProvider did not finish building without a relay '
                'client. It is awaited by stateManProvider, which is what '
                'builds that client, so this is the boot deadlock — on a '
                'panel it presents as a station that never comes up'));

    expect(prefs, isNotNull);
  });

  test('a shared write goes to the backend once the client arrives', () async {
    final container = _container(gateway: _gateway, holdStateMan: true);
    final backend = _Backend();
    addTearDown(backend.dispose);

    // Through the system path, not the guarded one: no session is signed in
    // here, and `alarm_man_config` is a `configure` key, so the checked path
    // would (correctly) refuse. What this arm is measuring is the transport
    // underneath the guard, not the guard.
    final prefs = await container.read(systemPreferencesProvider.future);
    container.read(gatewayPreferencesSlotProvider).fill(backend);

    await prefs.setString('alarm_man_config', '{"alarms":[]}');

    expect(backend.store['alarm_man_config'], '{"alarms":[]}',
        reason: 'this is the whole change: the shared configuration store of '
            'a gateway panel is the backend\'s');
  });

  test('a device-local key still never leaves the station', () async {
    final container = _container(gateway: _gateway, holdStateMan: true);
    final backend = _Backend();
    addTearDown(backend.dispose);

    final prefs = await container.read(systemPreferencesProvider.future);
    container.read(gatewayPreferencesSlotProvider).fill(backend);

    await prefs.setString(startupUrlPrefsKey, '/lines/1');

    expect(backend.store, isEmpty,
        reason: 'a shared startup_url row overwrites every station\'s own '
            'choice on the next sync — the bug #354 fixed');
    expect(
        await container
            .read(localPreferencesProvider)
            .getString(startupUrlPrefsKey),
        '/lines/1');
  });

  test('the backend\'s startup_url row is never touched from a panel',
      () async {
    // What this arm actually pins is the ROUTING, not the migration skip:
    // `startup_url` is device-local, so the migration's read and delete both
    // land on this station's own store and the backend's row is not its
    // business. (Skipping the migration in gateway mode is belt-and-braces on
    // top of that — it changes nothing observable today, which is why no arm
    // here reddens when it is removed. See the comment at the call site.)
    //
    // Remove the device-local routing, though, and this migration becomes one
    // panel deleting the row every other station reads — which is what this
    // arm is here to catch.
    final container = _container(gateway: _gateway, holdStateMan: true);
    final backend = _Backend();
    addTearDown(backend.dispose);
    backend.store[startupUrlPrefsKey] = '/somebody-elses-page';

    await container.read(preferencesProvider.future);
    container.read(gatewayPreferencesSlotProvider).fill(backend);
    await pumpEventQueue();

    expect(backend.store[startupUrlPrefsKey], '/somebody-elses-page',
        reason: 'the migration deletes the shared row it finds. On this '
            'transport that row is the BACKEND\'s, and deleting it would be '
            'one panel reaching across and changing a value it does not own');
  });

  test('direct mode is unchanged: a plain Preferences, and no slot in sight',
      () async {
    final container = ProviderContainer(overrides: [
      gatewayConfigProvider.overrideWith((ref) async => const GatewayConfig()),
      databaseProvider.overrideWith((ref) async => null),
    ]);
    addTearDown(container.dispose);

    final prefs = await container.read(systemPreferencesProvider.future);
    await prefs.setString('alarm_man_config', '{"alarms":[]}');

    // The direct path writes its memory cache and the device-local mirror,
    // with no wire anywhere. Reading it back through the same store is the
    // behaviour every existing direct-mode test relies on.
    expect(await prefs.getString('alarm_man_config'), '{"alarms":[]}');
    expect(container.read(gatewayPreferencesSlotProvider).api, isNull,
        reason: 'nothing in direct mode may fill the relay slot');
  });
}

@TestOn('vm')

/// A gateway panel with nobody signed in must still boot.
///
/// ## The deadlock this file exists to keep closed
///
/// Measured on the rig on 2026-09-09, against the live backend:
///
///  * a credential-less hello **is** admitted — a session id comes back;
///  * `preferences.getString` on that session is **refused**:
///    `awaiting_sign_in — nobody has signed in on this session, and a session
///    nobody signed in on may do nothing but wait. Sign in first`;
///  * `session.login` on that session **is** reachable — a deliberately wrong
///    password came back `bad_credentials`.
///
/// So the server is right and sign-in works. What did not work is the order:
/// `stateManProvider` reads `state_man_config` and `key_mappings` *in order to
/// build the client*, and once the shared store moved onto the relay those two
/// reads needed a client — and a signed-in one. Boot needed preferences,
/// preferences needed sign-in, sign-in needed a booted panel. The panel tore
/// down and retried forever: five sockets in TIME_WAIT and a screen that
/// looked disconnected, with nothing said.
///
/// Two changes that were each correct alone made it: an unauthenticated
/// session must hold nothing, and configuration belongs to the backend. The
/// fix is neither of those — it is that the two **boot** keys are bootstrapped
/// from the copy already on the device, and refreshed from the relay once a
/// session can read them.
///
/// ## What is pinned here, and why at this level
///
/// `state_man_transport_test.dart` overrides `preferencesProvider`, so it
/// cannot see this: the deadlock lives in the routing *inside*
/// `RelayedPreferences`, and a test that replaces the store replaces the bug.
/// Every arm below builds the real `preferencesProvider` in gateway mode and
/// drives `stateManProvider` through it, which is the pair that deadlocked.
///
/// A deadlock is the one failure a slow test machine and a plant look
/// identical for, so it is pinned with a real timeout rather than left to
/// reviewer attention.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/device_local_preferences.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/relayed_preferences.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/providers/gateway_preferences_slot.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show ClientConfig, RemoteStateMan;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as rp;

import '../helpers/test_helpers.dart' show FakeSecureStorage;

/// The backend's answer to every preferences call on a session nobody has
/// signed in on — the refusal quoted verbatim from the rig.
///
/// Every member refuses, including the ones no arm here calls: the claim being
/// tested is that boot needs **nothing** from this surface, and a fake that
/// answered anything would let a future edit lean on it unnoticed.
final class _AwaitingSignIn implements rp.PreferencesApi {
  /// Every key this surface was asked for, in order. Empty is the assertion.
  final List<String> asked = [];

  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.positionalArguments.isEmpty
        ? '${invocation.memberName}'
        : '${invocation.positionalArguments.first}';
    asked.add(key);
    return Future<Never>.error(StateError(
        'awaiting_sign_in — nobody has signed in on this session, and a '
        'session nobody signed in on may do nothing but wait. Sign in first'));
  }
}

/// A backend that answers, for the arms about adopting what it serves.
///
/// [refusing] makes it answer like a session nobody has signed in on, so one
/// object can play both halves of "booted refused, then somebody signed in".
final class _Backend implements rp.PreferencesApi {
  final Map<String, Object?> store = {};
  bool refusing = false;
  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  @override
  Future<String?> getString(String key) async {
    if (refusing) {
      throw StateError(
          'awaiting_sign_in — nobody has signed in on this session, and a '
          'session nobody signed in on may do nothing but wait. Sign in first');
    }
    return store[key] as String?;
  }

  @override
  Future<void> setString(String key, String value) async => store[key] = value;
  @override
  Stream<String> get onPreferencesChanged => _changes.stream;

  Future<void> dispose() => _changes.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'no arm here should need ${invocation.memberName}');
}

/// Thrown by the dial seam. Reaching it is the proof that boot got all the way
/// through its preference reads with no client and nobody signed in.
final class _ReachedTheDial implements Exception {
  @override
  String toString() => '_ReachedTheDial';
}

/// A plaintext loopback address nothing answers on. `undialable` lets it
/// through — what is under test is the reads that happen before the dial.
const _gateway = GatewayConfig(
  mode: TransportMode.gateway,
  url: 'ws://127.0.0.1:1',
);

/// The mapping and the config a panel finds in its own device-local cache: the
/// copy the rig panel already holds (11,827 and 134 characters of it), which
/// is what makes this fix work with data already on the device.
final _mirroredMappings = KeyMappings(nodes: {
  'Line1.temp': KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Temp')),
});

final _mirroredConfig = StateManConfig(opcua: [
  OpcUAConfig()
    ..endpoint = 'opc.tcp://10.104.29.10:4840'
    ..serverAlias = 'ST101',
]);

/// Puts both boot keys where a panel that has run before would have them.
///
/// `key_mappings` goes to the device-local store `Preferences.create` loads
/// its memory cache from; `state_man_config` goes to the keychain, because
/// `StateManConfig.fromPrefs` reads it with `secret: true`.
Future<void> _seedTheDeviceCache({
  KeyMappings? keyMappings,
  StateManConfig? config,
}) async {
  await SharedPreferencesAsync().setString(
      'key_mappings', jsonEncode((keyMappings ?? _mirroredMappings).toJson()));
  await SecureStorage.getInstance().write(
      key: StateManConfig.configKey,
      value: jsonEncode((config ?? _mirroredConfig).toJson()));
}

/// The panel, with the real `preferencesProvider` and a tripwire everywhere a
/// gateway station must not go.
///
/// [holdStateMan] parks `stateManProvider` instead of letting it build.
///
/// The arms that fill the slot by hand need it: a `stateManProvider` that
/// builds and fails calls `prefsSlot.fail`, which empties the slot again —
/// so the arm would be measuring an empty slot while believing it had filled
/// one. The deadlock arms must NOT hold it, because they are about that
/// provider finishing.
ProviderContainer _panel({
  GatewayConfig gateway = _gateway,
  GatewayStateManFactory? dial,
  bool holdStateMan = false,
}) {
  final container = ProviderContainer(overrides: [
    gatewayConfigProvider.overrideWith((ref) async => gateway),
    if (holdStateMan)
      stateManProvider.overrideWith((ref) => Completer<StateMan>().future),
    // 17-12's technique: in gateway mode the database dependency must not
    // merely go unused, it must be unreachable.
    databaseProvider.overrideWith((ref) async =>
        throw StateError('databaseProvider must not be read in gateway mode')),
    stateManFactoryProvider.overrideWithValue(({
      required StateManConfig config,
      required KeyMappings keyMappings,
      List<DeviceClient> deviceClients = const [],
    }) async =>
        throw StateError('a gateway station must build no local StateMan')),
    gatewayStateManFactoryProvider.overrideWithValue(dial ??
        ({
          required Uri uri,
          required ClientConfig clientConfig,
          required StateManConfig config,
          required KeyMappings keyMappings,
          String alias = '',
          RemoteStateMan Function({
            required Uri uri,
            required ClientConfig config,
            required Set<String> keys,
          })? buildRemote,
        }) async =>
            throw _ReachedTheDial()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
    Preferences.clearSecretCache();
    DatabaseConfig.clearPrefsCache();
  });

  group('the boot deadlock', () {
    test(
        'a gateway panel whose relayed preferences refuse with '
        'awaiting_sign_in still boots as far as the dial', () async {
      await _seedTheDeviceCache();
      final refusing = _AwaitingSignIn();
      addTearDown(refusing.dispose);

      StateManConfig? dialledWith;
      KeyMappings? dialledMappings;
      final container = _panel(dial: ({
        required Uri uri,
        required ClientConfig clientConfig,
        required StateManConfig config,
        required KeyMappings keyMappings,
        String alias = '',
        RemoteStateMan Function({
          required Uri uri,
          required ClientConfig config,
          required Set<String> keys,
        })? buildRemote,
      }) async {
        dialledWith = config;
        dialledMappings = keyMappings;
        throw _ReachedTheDial();
      });

      // The refusing backend is in the slot from the start — the worst case,
      // and the one the rig was in: the panel HAS a session, the server just
      // will not let it read anything until somebody signs in. Boot must not
      // consult it.
      container.read(gatewayPreferencesSlotProvider).fill(refusing);

      await expectLater(
        container.read(stateManProvider.future),
        throwsA(isA<_ReachedTheDial>()),
      ).timeout(const Duration(seconds: 10),
          onTimeout: () => fail(
              'the boot deadlock: stateManProvider never reached its dial. It '
              'reads state_man_config and key_mappings in order to build the '
              'client, so a read that needs the client — or needs a sign-in '
              'the panel cannot present until it has booted — is a station '
              'that never comes up'));

      // Asking is right — the relay is *preferred*, and a read that succeeds
      // is what refreshes the copy on the device. What must never happen is
      // depending on the answer, which is what the arm above measures.
      expect(refusing.asked, everyElement('key_mappings'),
          reason: 'state_man_config must not be asked of the relay at all: it '
              'is a secret, and the wire interface has no secret parameter');
      expect(dialledMappings?.nodes.keys, contains('Line1.temp'),
          reason: 'and the mapping it booted on is the one in its own cache, '
              'not a seeded default');
      expect(dialledWith?.opcua.single.serverAlias, 'ST101');
    });

    test('and it does so with no client at all — the slot is never filled',
        () async {
      await _seedTheDeviceCache();
      final container = _panel();

      await expectLater(
        container.read(stateManProvider.future),
        throwsA(isA<_ReachedTheDial>()),
      ).timeout(const Duration(seconds: 10),
          onTimeout: () => fail(
              'the boot deadlock in its purest form: nothing can fill the '
              'preferences slot except stateManProvider itself, so a boot '
              'read that parks for it waits for itself'));
    });
  });

  group('the bootstrap copy is a bootstrap, not a second home', () {
    test('a signed-in read refreshes the copy on the device', () async {
      await _seedTheDeviceCache();
      final backend = _Backend();
      addTearDown(backend.dispose);
      final theirs =
          jsonEncode(KeyMappings(nodes: {'Line2.flow': KeyMappingEntry()})
              .toJson());
      backend.store['key_mappings'] = theirs;

      final container = _panel(holdStateMan: true);
      final prefs = await container.read(systemPreferencesProvider.future);
      container.read(gatewayPreferencesSlotProvider).fill(backend);

      expect(await prefs.getString('key_mappings'), theirs,
          reason: 'once a session can read it, the relay is the answer');
      expect(await SharedPreferencesAsync().getString('key_mappings'), theirs,
          reason: 'and the copy on the device is refreshed by that read, so '
              'the next boot starts from what the plant last said');
    });

    test('a different value at the relay reaches the reload path', () async {
      await _seedTheDeviceCache();
      final backend = _Backend();
      addTearDown(backend.dispose);
      final theirs =
          jsonEncode(KeyMappings(nodes: {'Line2.flow': KeyMappingEntry()})
              .toJson());
      backend.store['key_mappings'] = theirs;

      final container = _panel(holdStateMan: true);
      final prefs = await container.read(preferencesProvider.future);
      final announced = <String>[];
      final sub = prefs.onPreferencesChanged.listen(announced.add);
      addTearDown(sub.cancel);

      container.read(gatewayPreferencesSlotProvider).fill(backend);
      await pumpEventQueue();

      expect(announced, contains('key_mappings'),
          reason: 'the panel booted on a stale copy; it must not keep running '
              'on it silently. This is the announcement `stateManProvider`\'s '
              'key_mappings listener rebuilds on');
    });

    test(
        'a panel that booted refused catches up when somebody signs in — one '
        'attempt at connection time is not enough', () async {
      await _seedTheDeviceCache();
      final backend = _Backend()..refusing = true;
      addTearDown(backend.dispose);
      final theirs = jsonEncode(
          KeyMappings(nodes: {'Line2.flow': KeyMappingEntry()}).toJson());
      backend.store['key_mappings'] = theirs;

      final container = _panel(holdStateMan: true);
      final prefs = await container.read(preferencesProvider.future);
      final announced = <String>[];
      final sub = prefs.onPreferencesChanged.listen(announced.add);
      addTearDown(sub.cancel);

      // The client arrives, and is refused: this is the panel's whole life
      // between boot and sign-in.
      container.read(gatewayPreferencesSlotProvider).fill(backend);
      await pumpEventQueue();
      expect(announced, isEmpty);
      expect(await SharedPreferencesAsync().getString('key_mappings'),
          isNot(theirs),
          reason: 'nothing could be read, so nothing may have been adopted');

      // Somebody signs in. `AccessSessionController._signInOverRelay` fires
      // exactly this, and it is the first moment the shared store is legible.
      backend.refusing = false;
      container.read(gatewayPreferencesSlotProvider).requestReconcile();
      await pumpEventQueue();

      expect(await SharedPreferencesAsync().getString('key_mappings'), theirs,
          reason: 'the bootstrap copy is refreshed the moment a session can '
              'read the real one — that is what bounds its staleness');
      expect(announced, contains('key_mappings'),
          reason: 'and the panel adopts it, on the reload path it already has');
    });
  });

  group('the two boot keys, by their two different routes', () {
    test('key_mappings is the wire-routed one, and is named as a boot key', () {
      expect(kBootstrapPreferenceKeys, contains('key_mappings'),
          reason: 'it is shared configuration on the wire, so the routing '
              'members need the set to know it is read before a client and '
              'before a sign-in exist');
    });

    test(
        'state_man_config is not named there, because a secret never reaches '
        'the wire in the first place', () {
      // Pinned rather than left to the library doc, because the obvious
      // "improvement" is to add it — and the mirror write is a plain
      // setString, so doing that would create a second, NON-secret home for a
      // key every real reader looks for in the keychain.
      expect(kBootstrapPreferenceKeys, isNot(contains(StateManConfig.configKey)));
    });

    test('and neither of them was quietly moved to the device-local side', () {
      // The bootstrap copy is a bootstrap, not a reclassification. Both keys
      // stay shared: `device_local_preferences.dart`'s boundary is about which
      // station OWNS a value, and both of these are the plant's.
      expect(isDeviceLocalPreferenceKey('key_mappings'), isFalse);
      expect(isDeviceLocalPreferenceKey(StateManConfig.configKey), isFalse);
    });
  });
}

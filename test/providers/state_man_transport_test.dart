/// Which implementation `stateManProvider` builds, and nothing else.
///
/// The two properties worth a test are the two that fail silently: a station
/// in gateway mode must **not** open OPC UA sessions, Modbus sockets and a
/// collector — and a station in direct mode must keep doing exactly that, on
/// the same seam it always did. Both are observed through
/// `stateManFactoryProvider`, the seam `guard_wiring_test.dart` already uses,
/// which is the only way to watch the local construction happen without
/// actually performing it.
///
/// **And, since Phase 15, what that implementation was pointed at.** Knowing a
/// `GatewayStateMan` was built says nothing about the address it dials, the
/// root it pins or the credential it presents — a panel silently dialling
/// somewhere other than its own preferences row looks exactly like a working
/// one until somebody reads `/proc/net/tcp` on both ends, which is how the rig
/// proved it once by hand (13-RIG-E2E-EVIDENCE). The `the dial target` group
/// below is the offline guard for that, and it observes the three arguments
/// through `gatewayStateManFactoryProvider` + `GatewayStateMan.create`'s
/// `buildRemote` seam **before a client exists**, because `RemoteStateMan`'s
/// constructor starts dialling.
library;

import 'dart:io';
import 'package:tfc/core/opcua_sessions.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/core/gateway_state_man.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show ClientConfig, RemoteStateMan;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' show AlarmKeys;

import '../helpers/test_helpers.dart';

/// What the gateway client was handed, recorded **before** one existed.
///
/// `RemoteStateMan.uri` and `.config` are public, so the obvious test reads
/// them off a constructed client. That constructed client is a live dial loop
/// at the configured address inside a unit test — the leak this file already
/// has one of at `:60-93`. These three are captured at the construction seam
/// instead, which runs before anything is allocated.
final class _RecordedDial {
  Uri? uri;
  ClientConfig? config;
  Set<String>? keys;
}

/// A port that is bound and immediately released, so nothing answers on it.
///
/// The stub client has to dial *something*; it must never be the address under
/// test, because then the assertion and the leak would be the same object.
Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// The real [GatewayStateMan.create], with its `RemoteStateMan` construction
/// recorded into [into] and replaced by an inert one.
///
/// Deliberately delegating to the real `create` rather than short-circuiting
/// it: half of what is under test is that `create` passes its arguments
/// through unaltered and computes the key set from the mapping it was given.
GatewayStateManFactory _recordingFactory(_RecordedDial into, int deadPort) => ({
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
    }) =>
        GatewayStateMan.create(
          uri: uri,
          clientConfig: clientConfig,
          config: config,
          keyMappings: keyMappings,
          alias: alias,
          buildRemote: ({
            required Uri uri,
            required ClientConfig config,
            required Set<String> keys,
          }) {
            into.uri = uri;
            into.config = config;
            into.keys = keys;

            // A fresh, minimal config: the recorded one may carry a pinned
            // root and a token, and `ClientConfig.checkDialable` refuses both
            // of those on the plaintext loopback dial this stub makes.
            final stub = RemoteStateMan(
              uri: Uri.parse('ws://127.0.0.1:$deadPort'),
              config: ClientConfig(
                backoffBase: const Duration(milliseconds: 40),
                backoffCap: const Duration(milliseconds: 200),
                connectTimeout: const Duration(milliseconds: 200),
              ),
              keys: const <String>{},
            );
            // At acquisition, not after the assertions (P-10). An undisposed
            // dial loop outlives its test and makes unrelated widget tests
            // flaky.
            addTearDown(stub.dispose);
            return stub;
          },
        );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  /// A container whose device-local store is [local], and whose local
  /// `StateMan` path is a tripwire rather than a real construction.
  ProviderContainer harness({
    required PreferencesApi local,
    void Function()? onLocalBuild,
  }) =>
      ProviderContainer(
        overrides: [
          preferencesProvider.overrideWith((ref) => createTestPreferences(
                stateManConfig: StateManConfig(opcua: const []),
              )),
          systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
                stateManConfig: StateManConfig(opcua: const []),
              )),
          localPreferencesProvider.overrideWithValue(local),
          stateManFactoryProvider.overrideWithValue(({
            required StateManConfig config,
            required KeyMappings keyMappings,
            List<DeviceClient> deviceClients = const [],
          }) async {
            onLocalBuild?.call();
            throw StateError('local StateMan construction reached');
          }),
        ],
      );

  test('a gateway station builds no local StateMan', () async {
    var localBuilt = false;
    final local = InMemoryPreferences();
    await writeGatewayConfig(
      local,
      // A port nothing answers on: the client dials in the background and
      // backs off. What is under test is which object was built, not whether
      // it connected.
      const GatewayConfig(
          mode: TransportMode.gateway, url: 'ws://127.0.0.1:1'),
    );

    final ref = harness(local: local, onLocalBuild: () => localBuilt = true);
    addTearDown(ref.dispose);

    final stateMan = await ref.read(stateManProvider.future);

    expect(localBuilt, isFalse,
        reason: 'a gateway station must open no OPC UA session, no Modbus '
            'socket and no collector of its own');

    // The object it did build behaves as the adapter: it hands out no live
    // upstream client objects, and it refuses connection metadata rather than
    // answering emptily. A local StateMan does neither.
    expect(opcUaSessionsOf(stateMan), isEmpty);
    expect(stateMan.deviceClients, isEmpty);
    expect(stateMan.connMetaAliases, isEmpty);
    expect(() => stateMan.subscribeConnMeta('plc1'),
        throwsA(isA<StateManException>()));

    // Access control is a property of the panel, not of the transport, so the
    // guard is still in front of it.
    expect(stateMan, isA<StateMan>());
  });

  // wss with no pinned root is the one combination that would otherwise fail
  // every handshake with the message a real impostor produces. The provider
  // refuses it by name rather than letting the panel report an attack.
  test('gateway mode with an undiallable address fails loudly', () async {
    final local = InMemoryPreferences();
    await writeGatewayConfig(
      local,
      const GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://10.50.10.11:9443'),
    );

    final ref = harness(local: local);
    addTearDown(ref.dispose);

    await expectLater(
        ref.read(stateManProvider.future), throwsA(isA<StateError>()));
  });

  test('an unconfigured station still takes the local path', () async {
    var localBuilt = false;
    final ref = harness(
        local: InMemoryPreferences(), onLocalBuild: () => localBuilt = true);
    addTearDown(ref.dispose);

    // The seam throws once reached, which is exactly the observation wanted:
    // direct mode is unchanged and still goes through it.
    await expectLater(
        ref.read(stateManProvider.future), throwsA(isA<StateError>()));
    expect(localBuilt, isTrue,
        reason: 'direct mode must keep building its own StateMan, on the same '
            'seam it always did');
  });

  // -------------------------------------------------------------------------
  // Criterion 1's other half: not *which object* was built, but what it was
  // pointed at. Every arm here compares against the preferences row the
  // operator actually typed, read back out of the device-local store.
  // -------------------------------------------------------------------------
  group('the dial target', () {
    /// Two mapped keys, so "the key set is the mapping's" is a statement with
    /// content rather than a comparison of two empty sets.
    final mappings = KeyMappings(nodes: {
      'Line1.temp': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Temp')),
      'Line1.press': KeyMappingEntry(
          opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Press')),
    });

    /// The same container the arms above build, plus the gateway construction
    /// seam. The direct-mode seam stays a tripwire: nothing here may reach it.
    ProviderContainer dialHarness({
      required PreferencesApi local,
      required GatewayStateManFactory factory,
    }) =>
        ProviderContainer(
          overrides: [
            preferencesProvider.overrideWith((ref) => createTestPreferences(
                  keyMappings: mappings,
                  stateManConfig: StateManConfig(opcua: const []),
                )),
            systemPreferencesProvider
                .overrideWith((ref) => createTestPreferences(
                      keyMappings: mappings,
                      stateManConfig: StateManConfig(opcua: const []),
                    )),
            localPreferencesProvider.overrideWithValue(local),
            stateManFactoryProvider.overrideWithValue(({
              required StateManConfig config,
              required KeyMappings keyMappings,
              List<DeviceClient> deviceClients = const [],
            }) async {
              throw StateError('local StateMan construction reached');
            }),
            gatewayStateManFactoryProvider.overrideWithValue(factory),
          ],
        );

    Directory scratch() {
      final dir = Directory.systemTemp.createTempSync('gateway-dial-target-');
      addTearDown(() => dir.deleteSync(recursive: true));
      return dir;
    }

    /// Seeds the device-local row and runs the provider to the point where the
    /// client would have been constructed.
    Future<_RecordedDial> dial(GatewayConfig row) async {
      final local = InMemoryPreferences();
      await writeGatewayConfig(local, row);

      final recorded = _RecordedDial();
      final ref = dialHarness(
        local: local,
        factory: _recordingFactory(recorded, await _deadPort()),
      );
      addTearDown(ref.dispose);

      await ref.read(stateManProvider.future);
      return recorded;
    }

    // The rig proved this by hand, from both ends' /proc/net/tcp. Compared as
    // a whole `Uri` rather than by `contains` or a `toString` match, so a
    // dropped port, a downgraded scheme or a host taken from anywhere but the
    // row all bite.
    test('dials the configured url, verbatim', () async {
      final ca = File('${scratch().path}/plant-root.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\n');

      final recorded = await dial(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: ca.path,
      ));

      expect(recorded.uri, Uri.parse('wss://10.50.10.11:9444'));
      // Spelled out as well as compared whole, so a failure names which half
      // moved instead of printing two similar URLs.
      expect(recorded.uri!.scheme, 'wss');
      expect(recorded.uri!.host, '10.50.10.11');
      expect(recorded.uri!.port, 9444);
    });

    // A dropped `ClientTlsConfig` is the mutation that turns a settings page
    // still reading `wss://` into an unpinned dial, so `tls` being present is
    // asserted before the path inside it.
    test('pins the CA path the row named', () async {
      final ca = File('${scratch().path}/plant-root.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\n');

      final local = InMemoryPreferences();
      final row = GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: ca.path,
      );
      await writeGatewayConfig(local, row);
      final saved = await readGatewayConfig(local);

      final recorded = _RecordedDial();
      final ref = dialHarness(
        local: local,
        factory: _recordingFactory(recorded, await _deadPort()),
      );
      addTearDown(ref.dispose);
      await ref.read(stateManProvider.future);

      expect(recorded.config!.tls, isNotNull,
          reason: 'a dropped ClientTlsConfig is a plaintext dial that still '
              'says wss:// in the settings page');
      expect(recorded.config!.tls!.rootCertPath, saved.caCertPath);
      expect(recorded.config!.tls!.rootCertPath, ca.path);
    });

    // `gateway_config.dart:151-159`'s discipline, pinned: the token is the
    // file's CONTENTS, read once, never written back, and the path never
    // reaches the client. A panel that presents its own filename as a
    // credential is refused by the gateway with a message about
    // authentication, which sends the engineer to the wrong end of the wire.
    test('hands over the credential, never its path', () async {
      final dir = scratch();
      final ca = File('${dir.path}/plant-root.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\n');
      final tokenFile = File('${dir.path}/station.token')
        ..writeAsStringSync('ST101-TOKEN-DO-NOT-LOG\n');
      final writtenAt = tokenFile.lastModifiedSync();

      final recorded = await dial(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: ca.path,
        tokenPath: tokenFile.path,
      ));

      expect(recorded.config!.token, 'ST101-TOKEN-DO-NOT-LOG');
      expect(recorded.config!.token, isNot(tokenFile.path));
      expect(recorded.config!.token, isNot(contains(dir.path)));

      // Read once and never written back — the whole reason the row holds a
      // path and not bytes.
      expect(tokenFile.readAsStringSync(), 'ST101-TOKEN-DO-NOT-LOG\n');
      expect(tokenFile.lastModifiedSync(), writtenAt);
    });

    // The client's key set is immutable after construction, so a short set is
    // a page of permanently grey values with no error anywhere — and a missing
    // `ALARM.active` is an alarm banner that simply never updates.
    test('subscribes this station\'s whole mapping, plus the alarm set',
        () async {
      final ca = File('${scratch().path}/plant-root.pem')
        ..writeAsStringSync('-----BEGIN CERTIFICATE-----\n');

      final recorded = await dial(GatewayConfig(
        mode: TransportMode.gateway,
        url: 'wss://10.50.10.11:9444',
        caCertPath: ca.path,
      ));

      expect(recorded.keys, {'Line1.temp', 'Line1.press', AlarmKeys.active});
      expect(recorded.keys, GatewayStateMan.subscriptionKeys(mappings));
    });
  });
}

/// Sign-in on a gateway panel, at the controller: the PRIMARY defect's fix.
///
/// Before increment B, `AccessSessionController.signIn` resolved the LOCAL
/// `authProvider` — null on a gateway panel — and returned `unavailable`
/// forever, so the photographed dialog read "Cannot reach the user database"
/// and nobody could sign in. Now it routes through the relay seam
/// (`relaySignInProvider` → `RemoteStateMan.sessionLogin`), the server
/// verifies, and this controller builds the session from what the server
/// resolved.
///
/// These arms drive the seam directly — overriding `relaySignInProvider` with
/// a fake — so each outcome is deterministic and needs no scripted gateway per
/// case. The wire, the server-side verification and the audit row are the
/// relay packages' own tested territory (`session_login_ws_test.dart`,
/// `session_login_client_test.dart`); this file is the controller mapping.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/gateway.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/secure_storage/secure_storage.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show LinkDown;
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../helpers/test_helpers.dart';

const _engineer = AuthenticatedUser(
    username: 'rig-panel-eng',
    roleName: 'Engineering',
    stationAccount: false);

/// A gateway panel container with the relay sign-in seam overridden.
///
/// [signIn] is the fake seam: null models "no relay client up" (→
/// unavailable), a function models a gateway that answers or refuses.
Future<ProviderContainer> _panel({
  required RelaySignIn? signIn,
  Object? throwOnSignIn,
}) async {
  final local = InMemoryPreferences();
  await writeGatewayConfig(
    local,
    const GatewayConfig(
        mode: TransportMode.gateway, url: 'wss://centroidx-backend:9443'),
  );
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences()),
      localPreferencesProvider.overrideWithValue(local),
      databaseProvider.overrideWith((ref) async => null),
      stationNameProvider.overrideWithValue('00fb2feb2a16'),
      relaySignInProvider.overrideWith((ref) async {
        if (throwOnSignIn != null) {
          return ({required username, required password, station}) =>
              throw throwOnSignIn;
        }
        return signIn;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

rpc.RpcException _refusal(String marker) =>
    rpc.RpcException(-32003, 'session.login refused: $marker — …');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    SecureStorage.setInstance(FakeSecureStorage());
  });

  test('a verified sign-in elevates the session to what the SERVER resolved',
      () async {
    final container = await _panel(
      signIn: ({required username, required password, station}) async {
        expect(username, 'rig-panel-eng');
        expect(password, 'correct-horse');
        return const SessionLoginResult(
          user: _engineer,
          groups: {AccessGroup.operate, AccessGroup.configure},
        );
      },
    );

    // Before: anonymous Operator floor.
    final before = await container.read(accessSessionProvider.future);
    expect(before.isElevated, isFalse);

    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.ok,
        reason: 'the gateway verified the credential and answered — the '
            'PRIMARY defect was that this path did not exist');

    final after = await container.read(accessSessionProvider.future);
    expect(after.isElevated, isTrue);
    expect(after.user, _engineer,
        reason: 'the session is built from the row the SERVER resolved, not '
            'from anything the panel decided');
    expect(after.groups, {AccessGroup.operate, AccessGroup.configure});
  });

  test('a gateway session is NOT persisted — no retained credential, per '
      'increment C being Jón\'s open decision', () async {
    final local = InMemoryPreferences();
    await writeGatewayConfig(
      local,
      const GatewayConfig(
          mode: TransportMode.gateway, url: 'wss://centroidx-backend:9443'),
    );
    final container = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith((ref) => createTestPreferences()),
        localPreferencesProvider.overrideWithValue(local),
        databaseProvider.overrideWith((ref) async => null),
        stationNameProvider.overrideWithValue('00fb2feb2a16'),
        relaySignInProvider.overrideWith((ref) async =>
            ({required username, required password, station}) async =>
                const SessionLoginResult(
                    user: _engineer, groups: {AccessGroup.operate})),
      ],
    );
    addTearDown(container.dispose);

    await container.read(accessSessionProvider.future);
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.ok);

    // The device-local store holds NO session payload: a reconnect lands
    // back at the sign-in screen, which is the whole of "sign in, get a
    // session for this run".
    expect(await local.getString(kAccessSessionPrefKey), isNull,
        reason: 'a persisted gateway session would be the panel asserting an '
            'identity across a restart with no server session behind it — '
            'exactly the client-supplied identity D-11 forbids');
  });

  test('bad credentials map to badCredentials — and to nothing else',
      () async {
    final container = await _panel(
      signIn: null,
      throwOnSignIn: _refusal(SessionAuthMarkers.badCredentials),
    );
    await container.read(accessSessionProvider.future);
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'wrong');
    expect(result, AccessSignInResult.badCredentials);
    final session = await container.read(accessSessionProvider.future);
    expect(session.isElevated, isFalse,
        reason: 'fail closed: a refused sign-in leaves the Operator floor');
  });

  test('an unreachable user source maps to unavailable, never badCredentials',
      () async {
    final container = await _panel(
      signIn: null,
      throwOnSignIn: _refusal(SessionAuthMarkers.userSourceUnavailable),
    );
    await container.read(accessSessionProvider.future);
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.unavailable,
        reason: 'a database blip is not somebody mistyping a password, and '
            'telling them it was sends them to reset one that was fine');
    expect(result, isNot(AccessSignInResult.badCredentials));
  });

  test('a dead link maps to unavailable', () async {
    final container = await _panel(
      signIn: null,
      throwOnSignIn: LinkDown('session.login'),
    );
    await container.read(accessSessionProvider.future);
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.unavailable,
        reason: 'no link is the honest "cannot reach", never a credential '
            'verdict');
  });

  test('no relay client up maps to unavailable', () async {
    final container = await _panel(signIn: null);
    await container.read(accessSessionProvider.future);
    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.unavailable);
  });
}

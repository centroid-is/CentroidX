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

import 'dart:async';

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
import 'package:tfc/core/gateway_link_status.dart';
import 'package:tfc/providers/gateway_link.dart';
import 'package:tfc/providers/gateway_preferences_slot.dart';
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
  List<Override> extra = const <Override>[],
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
      ...extra,
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

  test(
      'a verified sign-in asks for the bootstrap copy to be caught up — it is '
      'the first moment the shared store is legible', () async {
    // The panel booted on the copy of `key_mappings` in its own cache,
    // because a session nobody has signed in on may read nothing
    // (`relayed_preferences.dart`). Without this, that copy would go
    // unrefreshed for the whole run: the reconcile fires on `fill`, and a fill
    // happens before anyone signs in.
    final container = await _panel(
      signIn: ({required username, required password, station}) async =>
          const SessionLoginResult(
        user: _engineer,
        groups: {AccessGroup.operate, AccessGroup.configure},
      ),
    );

    // Built before the seam is watched: the notifier resolves the transport
    // row while it builds, and a `signIn` issued before that resolves takes
    // the direct path.
    await container.read(accessSessionProvider.future);

    var asked = 0;
    final sub = container
        .read(gatewayPreferencesSlotProvider)
        .onReconcileNeeded
        .listen((_) => asked++);
    addTearDown(sub.cancel);

    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'correct-horse');
    expect(result, AccessSignInResult.ok);
    await pumpEventQueue();

    expect(asked, 1,
        reason: 'a signed-in session is what bounds the staleness of the '
            'bootstrap copy the panel booted on');
  });

  test('a refused sign-in asks for nothing — there is still no session that '
      'may read the shared store', () async {
    final container =
        await _panel(signIn: null, throwOnSignIn: _refusal('bad_credentials'));

    await container.read(accessSessionProvider.future);

    var asked = 0;
    final sub = container
        .read(gatewayPreferencesSlotProvider)
        .onReconcileNeeded
        .listen((_) => asked++);
    addTearDown(sub.cancel);

    final result = await container
        .read(accessSessionProvider.notifier)
        .signIn('rig-panel-eng', 'wrong');
    expect(result, AccessSignInResult.badCredentials);
    await pumpEventQueue();

    expect(asked, 0);
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

    // And it STAYS unpersisted through activity: `poke()` extends a live
    // session and, in direct mode, re-persists it — the `_persist` gateway
    // guard is what keeps an operator's every pointer-down from writing the
    // session to disk on a gateway panel. Without this arm, removing that
    // guard reddens nothing (the sign-in path never calls `_persist`), so
    // this is the sabotage control for it.
    container.read(accessSessionProvider.notifier).poke();
    await Future<void>.delayed(Duration.zero);
    expect(await local.getString(kAccessSessionPrefKey), isNull,
        reason: 'activity must not persist a gateway session either — the '
            'guard is on _persist, not only on the sign-in path');
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

  // -------------------------------------------------------------------------
  // Revalidation and revocation on a gateway panel
  // -------------------------------------------------------------------------
  //
  // Two halves of ACCESS-01, and they have to be read together. The panel must
  // stop inventing a demotion out of the repository it was designed not to
  // have, and it must start honouring the one the server actually announces.
  // Fixing only the first would be trading a nuisance for a privilege that
  // never expires.

  group('the panel does not confirm accounts it cannot see', () {
    /// Signs the engineer in over the fake relay seam.
    Future<ProviderContainer> signedIn({
      List<Override> extra = const <Override>[],
    }) async {
      final container = await _panel(
        extra: extra,
        signIn: ({required username, required password, station}) async =>
            const SessionLoginResult(
          user: _engineer,
          groups: {AccessGroup.operate, AccessGroup.configure},
        ),
      );
      await container.read(accessSessionProvider.future);
      expect(
        await container
            .read(accessSessionProvider.notifier)
            .signIn('rig-panel-eng', 'correct-horse'),
        AccessSignInResult.ok,
      );
      return container;
    }

    test('refreshGroupsFromRoles leaves a relayed session alone', () async {
      // The rig defect, in one line of log: "Dropping the elevated session for
      // \"jon\" to anonymous: the database is unreachable". A gateway panel has
      // no repository BY DESIGN, and reading that absence as an outage demoted
      // a correctly signed-in engineer mid-shift.
      final container = await signedIn();
      expect(container.read(accessSessionProvider).valueOrNull!.isElevated,
          isTrue);

      await container
          .read(accessSessionProvider.notifier)
          .refreshGroupsFromRoles();

      final after = container.read(accessSessionProvider).valueOrNull!;
      expect(after.isElevated, isTrue,
          reason: 'the server verified this session and is the only thing '
              'that may retire it; the missing database is the transport, '
              'not an outage');
      expect(after.can(AccessGroup.configure), isTrue,
          reason: 'and it keeps what the server granted');
    });

    test('a link that goes away retires the relayed session — the server\'s '
        '4001 arriving as a link report', () async {
      // The control. The backend's revocation poll closes a demoted or deleted
      // account's session with 4001 on the next tick
      // (`session_login_ws_test.dart` arm 5); the client supervisor treats that
      // like any other close, so it reaches the app as a link that is no
      // longer connected. A gateway session does not survive its socket.
      final link = StreamController<GatewayLinkReport?>.broadcast();
      addTearDown(link.close);

      final container = await signedIn(extra: [
        gatewayLinkProvider.overrideWith((ref) => link.stream),
      ]);
      expect(container.read(accessSessionProvider).valueOrNull!.isElevated,
          isTrue);

      link.add(_report(GatewayLinkKind.unreachable));
      await _settle();

      final after = container.read(accessSessionProvider).valueOrNull!;
      expect(after.isElevated, isFalse,
          reason: 'the session it was minted on is gone; keeping the '
              'elevation would be the panel asserting an identity with '
              'nothing behind it');
      expect(after.can(AccessGroup.configure), isFalse);
    });

    test('a connected link leaves the session exactly where it is', () async {
      // Not a blanket drop: the control must cost nothing on a healthy panel,
      // or it becomes an operator signed out every time a report lands.
      final link = StreamController<GatewayLinkReport?>.broadcast();
      addTearDown(link.close);

      final container = await signedIn(extra: [
        gatewayLinkProvider.overrideWith((ref) => link.stream),
      ]);

      link.add(_report(GatewayLinkKind.connected));
      await _settle();

      expect(container.read(accessSessionProvider).valueOrNull!.isElevated,
          isTrue);
    });
  });
}

/// A link report of [kind]; only the kind is read by the session controller.
GatewayLinkReport _report(GatewayLinkKind kind) => GatewayLinkReport(
      kind: kind,
      headline: 'headline',
      detail: 'detail',
      url: Uri.parse('wss://centroidx-backend:9443'),
    );

/// Lets the listener's fire-and-forget drop run to completion.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

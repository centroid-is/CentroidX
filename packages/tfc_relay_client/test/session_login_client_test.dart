@TestOn('vm')

/// The client half of `session.login`: one request out, the SERVER's answer
/// decoded, and nothing decided on this side — the panel's sign-in screen is
/// a dumb terminal to the gateway's verifier.
///
/// What is deliberately NOT here: no retained credential (increment C is the
/// owner's open decision — a reconnect lands back at the sign-in screen), no
/// client-side password digest (a client-computed digest IS the password),
/// and no special-casing of the refusal — the gateway's `RpcException`
/// surfaces whole, marker vocabulary included, for the app to map to a
/// screen.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'support/client_harness.dart';

const _password = 'HANDAN-fjalla-0900-lykill';

const _engineer = AuthenticatedUser(
    username: 'jon', roleName: 'Engineering', stationAccount: false);

final class _Verifier implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
          String username, String password) async =>
      username == 'jon' && password == _password ? _engineer : null;
}

ResolvedUser? _resolve(String username) => username == 'jon'
    ? const ResolvedUser(
        user: _engineer,
        groups: {AccessGroup.operate, AccessGroup.configure})
    : null;

void main() {
  test('sessionLogin sends the credential once and hands back what the '
      'SERVER resolved; the value barrier opens only after', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);

    // Before the sign-in: the client is admitted (session gate open) but not
    // READY — the value barrier is shut because an awaiting session may
    // subscribe to nothing. This is the anti-vacuity control for the lift
    // below, and the fix for the PRIMARY defect's client half: the supervisor
    // did NOT stop the retry loop on the awaiting-sign-in refusal.
    await fixture.client.sessionReady;
    expect(fixture.client.isReady, isFalse,
        reason: 'an awaiting session is a live socket with a shut value '
            'barrier — a sign-in screen, not a ready link');
    expect(fixture.client.stopReason, isNull,
        reason: 'the awaiting refusal must not have stopped the loop the way '
            'a refused credential does — the panel shows a sign-in screen, '
            'never "the gateway refused this panel"');

    final result = await fixture.client.sessionLogin(
        username: 'jon', password: _password, station: 'PACK-02');
    expect(result.user, _engineer,
        reason: 'the answer is the row the server resolved — this client '
            'supplied a username, a password and a station label, nothing '
            'else, and believes nothing it did not receive');
    expect(result.groups, {AccessGroup.operate, AccessGroup.configure});

    // After: the gate lifted, the deferred resync ran, and a fresh read now
    // reaches the plant.
    expect(fixture.client.isReady, isTrue,
        reason: 'resumeAfterSignIn drove the resync the awaiting state '
            'deferred; the value barrier is open');
    await fixture.client.readFresh('t1');
  });

  test('a wrong password surfaces the gateway\'s own refusal, marker intact, '
      'and the password reaches no supervisor reason surface', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);

    await expectLater(
        fixture.client
            .sessionLogin(username: 'jon', password: 'not-the-password'),
        throwsA(isA<rpc.RpcException>().having((e) => e.message, 'message',
            contains(SessionAuthMarkers.badCredentials))));

    // The refusal must not have become a link fact: the supervisor's two
    // reason surfaces are operator-facing prose, and a login refusal is a
    // screen's business, not the link's.
    expect(fixture.client.stopReason, isNull,
        reason: 'a refused sign-in must not stop the retry loop the way a '
            'refused HELLO credential does — the session is fine, somebody '
            'mistyped');
    expect(fixture.client.lastDownReason, isNull);
  });

  test('sessionLogout completes, and the session is nobody again', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);

    await fixture.client
        .sessionLogin(username: 'jon', password: _password);
    await fixture.client.readFresh('t1');
    expect(fixture.client.isReady, isTrue);

    await fixture.client.sessionLogout();
    // Idempotent: a second logout answers rather than throwing — a reconnect
    // may have reset the far end without this client knowing.
    await fixture.client.sessionLogout();
  });

  group('verifiedAccount, from the hello answer', () {
    test('a gateway that names the verified account answers it; display '
        'material only', () async {
      // The permissive default mints a self-naming identity, so the hello
      // carries its username — which is exactly the advisory-display
      // behaviour: the panel prints what the gateway verified, whatever
      // that is.
      final fixture = relayFixture();
      addTearDown(fixture.teardown);
      await fixture.client.readFresh('t1'); // barrier: the hello has landed
      expect(fixture.client.verifiedAccount,
          PermissiveTokenValidator.stationId,
          reason: 'the capability rides every non-sentinel hello answer — '
              'the attribution row names the account, not the machine');
    });

    test('a credential-less (awaiting) session has NO verified account',
        () async {
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: _resolve),
        accounts: _resolve,
        loginVerifier: _Verifier(),
      );
      addTearDown(fixture.teardown);
      // The session gate opens at hello; the account is read from that same
      // answer, and an awaiting one carries none.
      await fixture.client.sessionReady;
      expect(fixture.client.verifiedAccount, isNull,
          reason: 'nobody is not an account: prose that printed the '
              'sentinel\'s self-naming string as one would be the lie its '
              'names exist to prevent');
    });
  });
}

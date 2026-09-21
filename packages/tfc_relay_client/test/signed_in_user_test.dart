@TestOn('vm')

/// `RemoteStateMan.signedInUser` — the name the gateway verified at this
/// session's `session.login`, held for attribution prose and nothing else.
///
/// `session_login_client_test.dart`'s harness and helpers; this file pins
/// only the retained name, which that file's arms never ask about.
@Tags(['ws'])
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
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
  test('null while nobody is signed in, the verified username after, null '
      'again on sign-out', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);
    await fixture.client.sessionReady;

    expect(fixture.client.signedInUser, isNull,
        reason: 'an awaiting session is nobody');

    await fixture.client.sessionLogin(username: 'jon', password: _password);
    expect(fixture.client.signedInUser, 'jon',
        reason: 'the name the SERVER answered, not the one typed — the two '
            'agree here, and the login test pins that the answer is what '
            'is believed');

    // A page opening is a re-subscribe inside the same session, and it must
    // not read as a new session: the first cut cleared the name on every
    // establishment and the attribution line went blank the moment the
    // server-config page subscribed to anything.
    final sub = fixture.client.subscribe('t1').listen((_) {});
    addTearDown(sub.cancel);
    await fixture.client.readFresh('t1');
    expect(fixture.client.signedInUser, 'jon',
        reason: 'a subscribe after the sign-in is the same session');

    final logout = fixture.client.sessionLogout();
    expect(fixture.client.signedInUser, isNull,
        reason: 'cleared before the request leaves, the gateway\'s own '
            'ordering: nothing reading the name during the sign-out may '
            'still attribute to the person leaving');
    await logout;
    expect(fixture.client.signedInUser, isNull);
  });

  test('a refused sign-in leaves it null', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);
    await fixture.client.sessionReady;

    await expectLater(
        fixture.client
            .sessionLogin(username: 'jon', password: 'not-the-password'),
        throwsA(anything));
    expect(fixture.client.signedInUser, isNull);
  });
}

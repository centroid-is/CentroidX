@TestOn('vm')
@Tags(['ws'])

/// Adversarial round 2 (client): the shape of a graded refusal, both ends.
///
/// `withAccessErrors` (`client_sub_apis.dart`) turns a `-32005` into a
/// `RemoteAccessDenied` by reading `data['itemKey']` and `data['group']`,
/// defaulting to `'unknown'` and `AccessGroup.users`. The gateway's every
/// graded refusal is minted by `refusedForGroup`
/// (`policy/policy_state_man.dart`) with `data: substitutedRequest(method)` —
/// `{method, request}` — and names the missing group only in prose. So on a
/// real gateway the typed `required` is `users` whatever the policy wanted,
/// and `itemKey` is the literal string `unknown`. `access_proxies_test.dart`
/// asserts the translation against a hand-written `{itemKey, group}` data
/// map the server never sends; the parity sweep names the 37 access checks
/// as its unswept gap, so nothing compared the two ends until now.
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'support/client_harness.dart';
import 'support/fault_fixture.dart' show until;
import 'support/gate_bands.dart';

const String _password = 'HANDAN-fjalla-0900-lykill';

const _admin = AuthenticatedUser(
    username: 'gestur', roleName: 'User Admin', stationAccount: false);

final class _Verifier implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
          String username, String password) async =>
      username == 'gestur' && password == _password ? _admin : null;
}

// Holds `operate` (so the value barrier opens) and `users`, and nothing else.
ResolvedUser? _resolve(String username) => username == 'gestur'
    ? const ResolvedUser(
        user: _admin, groups: {AccessGroup.operate, AccessGroup.users})
    : null;

void main() {
  test(
      'a graded refusal reaches the caller as AccessDenied naming the group '
      'the gateway named', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
    );
    addTearDown(fixture.teardown);
    await fixture.client
        .sessionLogin(username: 'gestur', password: _password)
        .timeout(recovery);
    await until('the link', () => fixture.client.isReady);

    Object? thrown;
    try {
      await fixture.client.backendConfig.read().timeout(recovery);
    } catch (error) {
      thrown = error;
    }
    print('backendConfig.read() as users+operate -> ${thrown.runtimeType}: '
        '$thrown');
    expect(thrown, isNotNull,
        reason: 'premise: backendConfig.read is graded above users on the '
            'gateway (policy_access_gate_test: "every backendConfig member '
            'takes administer")');
    expect(thrown, isA<AccessDenied>(),
        reason: 'the refusal did not arrive as the type direct mode throws; '
            'a settings screen that catches AccessDenied shows a raw '
            'JSON-RPC error instead');

    final denied = thrown! as AccessDenied;
    final message = '$denied';
    expect(message, contains('"${denied.required.name}"'),
        reason: 'the typed `required` group is ${denied.required.name}, and '
            'the gateway\'s own sentence names a different one: "$message". '
            '`withAccessErrors` reads `data[\'group\']`, the gateway sends '
            '`substitutedRequest(method)` with no such field, and the '
            'fallback is `AccessGroup.users` — so the screen tells the '
            'operator to ask for the wrong permission');
    expect(denied.itemKey, isNot('unknown'),
        reason: 'the typed itemKey is the literal "unknown": the gateway '
            'sends no `itemKey` in its refusal data');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

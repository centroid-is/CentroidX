@TestOn('vm')

/// `session.logout` gives the identity up **before** it writes the row about
/// it — so nothing dispatched while that row is in flight is graded as the
/// person who just left.
///
/// Found by adversarial review: the handler awaited the audit sink first and
/// swapped the identity afterwards. json_rpc_2 dispatches without awaiting
/// between frames, so a `write` sent while the sink was slow — or batched
/// `[logout, write]` — was still graded as the signed-in engineer, applied,
/// and recorded under a name that had signed out. A trail that says somebody
/// acted after they left is the wrong-audit case D-05 exists to prevent.
@Tags(['ws'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/session_login_validator.dart';

import 'support/ws_harness.dart';

const _key = 'CN01.MOT01.speed';
const _secret = 'ÞYRNIGERÐI-9000-lykilorð';
const _engineer = AuthenticatedUser(
    username: 'jon', roleName: 'Engineering', stationAccount: false);

final class _Verifier implements AuthProvider {
  @override
  Future<AuthenticatedUser?> authenticate(
          String username, String password) async =>
      username == 'jon' && password == _secret ? _engineer : null;
}

ResolvedUser? _resolve(String username) => username == 'jon'
    ? ResolvedUser(
        user: _engineer,
        groups: const {AccessGroup.operate, AccessGroup.configure})
    : null;

/// A sink that holds the logout row until told to let go — the slow
/// database the race needs, made deterministic.
final class _StallingSink implements AuditSink {
  final rows = <AuditRecord>[];
  final logoutHeld = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> record(AuditRecord entry) async {
    rows.add(entry);
    if (entry.itemKey == 'logout') {
      if (!logoutHeld.isCompleted) logoutHeld.complete();
      await release.future;
    }
  }
}

void main() {
  test('a write dispatched while the logout row is in flight is graded as '
      'nobody, not as the person who just signed out', () async {
    final sink = _StallingSink();
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      loginVerifier: _Verifier(),
      accounts: _resolve,
      audit: sink,
    );
    await fixture.ready;
    await fixture.hello();
    fixture.served.setValue(_key, 1200);
    await fixture.request(Methods.sessionLogin,
        params: SessionLoginParams(username: 'jon', password: _secret)
            .toJson());

    // Logout, with its audit row held open by the sink. Not awaited: the
    // race is what happens on this session while it is in flight.
    final logout = fixture.request(Methods.sessionLogout, params: const {});
    await sink.logoutHeld.future;

    final before = fixture.served.upstreamWriteAttempts;
    final refusal = await fixture.refusal(Methods.write,
        params: {'cmd': newUlid(), 'key': _key, 'value': 1450},
        what: 'a write sent while the logout row was in flight');
    expect(refusal, isNotNull);
    expect(fixture.served.upstreamWriteAttempts, before,
        reason: 'the session had already given its identity up; a session '
            'nobody is signed in on holds nothing here, so the plant must '
            'not have been touched');
    expect(
        sink.rows.where((r) => r.itemKey == _key && r.who == 'jon'), isEmpty,
        reason: 'no row may say the engineer acted after signing out');

    sink.release.complete();
    await logout;
    await fixture.teardown();
  });
}

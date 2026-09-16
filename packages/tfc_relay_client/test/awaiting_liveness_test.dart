@TestOn('vm')

/// A panel with nobody signed in has to STAY connected long enough for
/// somebody to sign in. One process: a real `RelayServer`, a real
/// `RemoteStateMan`, a real socket between them.
///
/// **This is the arm that was missing, and its absence cost a day.** On
/// 2026-09-09 a gateway panel on the rig could not be signed into, and the
/// reason took three deploys to find because every part looked correct in
/// isolation:
///
///  * the gateway admitted a credential-less hello — verified on the wire;
///  * `session.login` was reachable on that session — verified on the wire;
///  * `session_login_client_test.dart` signed in successfully — because it
///    signs in IMMEDIATELY, inside the deadline, and never waits.
///
/// What no test did was wait. The heartbeat pump started on `isReady`, which
/// is the VALUE barrier and stays shut on an awaiting session by design, so
/// the panel fell silent and the gateway closed it on its own liveness
/// deadline: `4003 — no heartbeat for 6098 ms; the deadline is 6000 ms`. It
/// reconnected, went awaiting, fell silent, and was reaped again — a
/// six-second cycle in which no human can type a username and a password. The
/// sign-in screen was reachable and unusable.
///
/// Two fixes were needed and each was invisible without the other. The pump
/// had to beat while awaiting, and the supervisor had to ANNOUNCE the awaiting
/// state — it stays in `resyncing` on purpose and `_enter` de-duplicates, so
/// the state stream never fired, and the first fix was dead code on a path
/// nothing told it about.
///
/// So the property is not "a login works". It is **"a login still works after
/// the gateway's liveness deadline has passed"**, which is the only version of
/// it a person at a panel ever exercises.
///
/// The deadline here is deliberately far below what a real gateway accepts,
/// the way `liveness_test.dart` does it and for the same reason: these arms
/// are about the mechanism, not the number, and a suite that waits six seconds
/// an arm is a suite somebody deletes.
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart' show ClientConfig;
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'support/client_harness.dart';

const _password = 'HANDAN-fjalla-0900-lykill';

const _engineer = AuthenticatedUser(
    username: 'jon', roleName: 'Engineering', stationAccount: false);

/// Short enough to keep the suite quick, long enough that a client beating at
/// its own floor can MEET it — the two bounds this number sits between, and
/// the second one is not optional.
///
/// `ClientConfig.heartbeatFloor` is 1 s and the pump's skip-on-traffic rule
/// lets the gateway see up to two floors of silence between beats, so a
/// deadline at or below 2 s reaps a perfectly healthy panel. The first draft
/// of this arm used 400 ms and failed WITH both fixes in place — which read
/// for a moment like the fixes not working, and was really this file
/// configuring a gateway that reaps everything. 07-REVIEW WR-01 is the same
/// finding from the other side.
const _deadline = Duration(milliseconds: 1400);

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

ServerConfig _reapingConfig() => ServerConfig(
      tick: ServerConfig.minTick,
      heartbeatDeadline: _deadline,
      // At the floor rather than below it: unlike `liveness_test.dart`, this
      // arm needs a deadline a HEALTHY client can meet, because the defect is
      // a client that goes silent and not a gateway that reaps too eagerly.
      minHeartbeatDeadline: _deadline,
      // Must exceed the deadline (ServerConfig enforces it): a ping the
      // deadline cannot beat leaves a window where the gateway serves a
      // dead panel's subscriptions to nobody.
      pingInterval: const Duration(seconds: 3),
    );

void main() {
  test('an awaiting session outlives the liveness deadline, and a sign-in '
      'still lands after it has passed', () async {
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
      config: _reapingConfig(),
    );
    addTearDown(fixture.teardown);

    await fixture.client.sessionReady;

    // The control: this IS the awaiting state, not a ready link that would
    // pass the arm below for the wrong reason.
    expect(fixture.client.isReady, isFalse,
        reason: 'an awaiting session is a live socket with a shut value '
            'barrier — if this is already ready, the wait below proves '
            'nothing about awaiting sessions');
    expect(fixture.client.stopReason, isNull);

    // **Watch the gateway's own closes, because the obvious signals are
    // blind to this defect.**
    //
    // The first draft of this arm asserted `stopReason` and a successful
    // login, and it PASSED with the fix reverted — a reaped client
    // reconnects, and the login lands on a fresh session. That is the rig
    // failure exactly: the panel does keep getting a socket, and what makes
    // it unusable is that the socket the operator started typing into is not
    // the one there when they press the button. A test that only checks the
    // end state cannot see it, so this counts the closes instead.
    var closedByGateway = 0;
    final watch = fixture.server.sessions.gone.listen((_) => closedByGateway++);
    addTearDown(watch.cancel);

    // The wait that no other arm does. Two full deadlines: long enough that a
    // pump which never started is certainly past the limit, short enough that
    // the suite stays runnable.
    await Future<void>.delayed(_deadline * 3);

    expect(closedByGateway, 0,
        reason: 'the gateway closed $closedByGateway session(s) while nobody '
            'was signed in, so it reaped an awaiting panel and the client '
            'silently reconnected. An operator halfway through typing a '
            'password is on the session that died');
    expect(fixture.server.sessions.sessionCount, 1,
        reason: 'exactly one session, and it is the one the panel was '
            'admitted on');

    expect(fixture.client.stopReason, isNull,
        reason: 'the gateway closed the session while nobody was signed in. '
            'That is the rig defect: the panel shows a sign-in screen, the '
            'far end reaps it on its liveness deadline, and the operator is '
            'typing into a socket that keeps dying under them');

    // And the session is not merely open — it still works. A socket held by
    // TCP alone, with a far end that has forgotten it, would fail here.
    final result = await fixture.client.sessionLogin(
        username: 'jon', password: _password, station: 'PACK-02');
    expect(result.user, _engineer,
        reason: 'the sign-in the operator came for, attempted after the '
            'deadline the way a real one always is');
    expect(fixture.client.isReady, isTrue,
        reason: 'the gate lifted and the deferred resync ran');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a policy refusal during connect opens exactly one socket: the link is '
      'held past the freshness deadline, not redialled', () async {
    // The reconnect loop measured on 2026-09-16: the resync subscribe was
    // refused with the sign-in marker, the supervisor held — and three seconds
    // later the freshness watchdog, seeing no frame, took the link down and
    // redialled into the same refusal. Seven sockets in 35 s, a banner
    // blinking "gateway unreachable" on a session that was fine.
    const deadline = Duration(milliseconds: 300);
    final fixture = relayFixture(
      validator: SessionLoginValidator(accounts: _resolve),
      accounts: _resolve,
      loginVerifier: _Verifier(),
      clientConfig: ClientConfig(
        controlDeadline: const Duration(milliseconds: 200),
        writeDeadline: const Duration(milliseconds: 400),
        freshnessDeadline: deadline,
        backoffBase: const Duration(milliseconds: 20),
        backoffCap: const Duration(milliseconds: 100),
        deadlineFloor: const Duration(milliseconds: 50),
      ),
    );
    addTearDown(fixture.teardown);
    var gone = 0;
    final watch = fixture.server.sessions.gone.listen((_) => gone++);
    addTearDown(watch.cancel);

    await fixture.client.sessionReady;
    expect(fixture.client.awaitingSignIn, isTrue,
        reason: 'the connect-path subscribe was refused with the marker: '
            'this is the hold under test');

    // Five freshness deadlines, with nothing subscribed and nothing arriving
    // but ping answers.
    await Future<void>.delayed(deadline * 5);

    expect(fixture.client.awaitingSignIn, isTrue,
        reason: 'still held: a redial would have minted a fresh hello and '
            'landed in the hold again, but through `_down`');
    expect(fixture.client.lastDownReason, isNull,
        reason: 'the watchdog must not read expected silence as a half-open '
            'socket while the session is held for policy');
    expect(fixture.client.stopReason, isNull);
    expect(gone, 0,
        reason: 'no session ended — the socket the panel was admitted on is '
            'the socket it is still on');
    expect(fixture.server.sessions.sessionCount, 1,
        reason: 'exactly one socket, ever, for this sign-in screen');
  }, timeout: const Timeout(Duration(seconds: 30)));
}

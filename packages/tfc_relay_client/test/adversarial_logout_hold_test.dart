@TestOn('vm')
@Tags(['ws'])

/// Adversarial round 2 (client): what a sign-out leaves behind.
///
/// `RemoteStateMan.sessionLogout` clears `signedInUser` and sends the request.
/// It releases no hold, shuts no barrier and clears no store; the supervisor's
/// `awaitingSignIn` stays false and `LinkState` stays `ready`. The gateway's
/// `_sessionLogout` returns the session to nobody and clears its
/// subscriptions but keeps its holds (`releaseAllHolds` runs only in
/// `_teardown`) and `holdTick` consults no identity — so the two ends together
/// let a deadman counter keep advancing for a session nobody is signed in on.
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_client/src/deadline.dart' show LinkDown;
import 'package:tfc_relay_client/src/hold_to_run_controller.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

import 'support/client_harness.dart';
import 'support/fault_fixture.dart' show until;
import 'support/gate_bands.dart';

const String _key = 'ST101.CN01.MOT01.setpoint';
const String _password = 'HANDAN-fjalla-0900-lykill';
const Duration _pulse = Duration(milliseconds: 25);

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

RelayFixture _signedInFixture() {
  final fixture = relayFixture(
    validator: SessionLoginValidator(accounts: _resolve),
    accounts: _resolve,
    loginVerifier: _Verifier(),
  );
  addTearDown(fixture.teardown);
  fixture.served.setValue(_key, 0);
  return fixture;
}

void main() {
  group('sign-out under a live hold', () {
    test('the deadman counter stops advancing once the operator signs out',
        () async {
      final fixture = _signedInFixture();
      await fixture.client
          .sessionLogin(username: 'jon', password: _password)
          .timeout(recovery);
      await until('the link', () => fixture.client.isReady);

      final controller = HoldToRunController(
        api: fixture.client,
        key: _key,
        pulsePeriod: _pulse,
      );
      addTearDown(controller.dispose);
      final engagement = await controller.press().timeout(recovery);
      expect(engagement, isA<WriteApplied>(),
          reason: 'no live hold, so the sign-out below is under nothing');
      await until('the counter to advance at the plant',
          () => (fixture.served.read(_key)?.asInt ?? 0) >= 4,
          budget: recovery);

      await fixture.client.sessionLogout().timeout(recovery);

      // Longer than any deadman the two ends run: a hold nobody feeds falls
      // well inside this.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final atSettle = fixture.served.read(_key)?.asInt;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final later = fixture.served.read(_key)?.asInt;
      print('sign-out under hold: counter $atSettle then $later, '
          'controller held ${controller.isHeld}, ticks sent '
          '${fixture.client.debugHoldTicksSent}, client ready '
          '${fixture.client.isReady}, signedInUser '
          '${fixture.client.signedInUser}');

      expect(later, atSettle,
          reason: 'the deadman counter at the plant moved from $atSettle to '
              '$later after the sign-out. The client kept ticking (its link '
              'is still `ready`), the gateway kept its hold across the '
              'logout and `holdTick` consults no identity — a machine kept '
              'jogging for a session nobody is signed in on');
      expect(controller.isHeld, isFalse,
          reason: 'the controller still reports a live hold after the person '
              'holding it signed out. The identity that authorised the '
              'engage is gone from the gateway; nothing on this client '
              'released the hold or stopped the pulse timer');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('what the client says after a sign-out', () {
    test('the far end refuses reads, and the client still reports ready',
        () async {
      final fixture = _signedInFixture();
      await fixture.client
          .sessionLogin(username: 'jon', password: _password)
          .timeout(recovery);
      await until('the link', () => fixture.client.isReady);
      await fixture.client.readFresh('t1').timeout(recovery);

      await fixture.client.sessionLogout().timeout(recovery);

      Object? refusal;
      try {
        await fixture.client.readFresh('t1').timeout(recovery);
      } catch (error) {
        refusal = error;
      }
      print('after sign-out: readFresh -> $refusal, isReady '
          '${fixture.client.isReady}, awaitingSignIn '
          '${fixture.client.awaitingSignIn}, linkState '
          '${fixture.client.linkState}');
      // Refused either way: by the gateway (the session is nobody), or —
      // since the sign-out now shuts the value barrier — by this client
      // before the read leaves, which is the better of the two.
      expect(refusal, anyOf(isA<rpc.RpcException>(), isA<LinkDown>()),
          reason: 'a read after the sign-out must not be answered');

      expect(fixture.client.awaitingSignIn, isTrue,
          reason: '`awaitingSignIn` is documented as "the socket is up and '
              'the sign-in screen is the thing to show". The far end is '
              'awaiting a sign-in and this client says it is not');
      expect(fixture.client.isReady, isFalse,
          reason: 'the value barrier is open on a session the gateway '
              'refuses every read for; a caller that checks `isReady` before '
              'acting is told to go ahead');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a plant change after the sign-out never reaches the page, and the '
        'page is not marked stale', () async {
      final fixture = _signedInFixture();
      await fixture.client
          .sessionLogin(username: 'jon', password: _password)
          .timeout(recovery);
      await until('the link', () => fixture.client.isReady);
      fixture.served.setValue(_key, 5);
      await until('the value to land', () => fixture.client.read(_key)?.value == 5,
          budget: recovery);

      await fixture.client.sessionLogout().timeout(recovery);
      fixture.served.setValue(_key, 6);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final shown = fixture.client.read(_key);
      print('after sign-out: page shows $shown, viewIsStale '
          '${fixture.client.viewIsStale}, staleSubscriptions '
          '${fixture.client.staleSubscriptions}, isReady '
          '${fixture.client.isReady}');
      final honest = shown?.value == 6 ||
          shown?.quality != Quality.good ||
          fixture.client.viewIsStale ||
          !fixture.client.isReady;
      expect(honest, isTrue,
          reason: 'the page shows ${shown?.value} under ${shown?.quality} '
              'with the view fresh and the link ready, while the plant reads '
              '6 and the gateway has dropped this session\'s subscriptions. '
              'The heartbeat keeps the link deadline fed, so a frozen plant '
              'is rendered as a live one for as long as nobody signs in');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}

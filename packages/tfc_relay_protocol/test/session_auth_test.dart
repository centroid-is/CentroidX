/// The `session.login` wire shapes: the withholding rule on the credential,
/// the round trips, and the spellings both ends match on.
///
/// The password arm drives a distinctive secret — never a plausible password,
/// so if it shows up in a `toString` it can only have come from the field —
/// which is `policy_access_gate_test.dart`'s FIX 2 discipline applied at the
/// shape itself, before any server exists to leak it.
library;

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

const _secret = 'ÞYRNIGERÐI-9000-lykilorð';

void main() {
  group('SessionLoginParams', () {
    test('withholds the password from toString — the F-B rule, at the shape',
        () {
      const params = SessionLoginParams(
          username: 'jon', password: _secret, station: 'PACK-02');
      final printed = params.toString();
      expect(printed, isNot(contains(_secret)),
          reason: 'toString output reaches log files that live longer and '
              'travel further than the database does');
      expect(printed, contains('<withheld>'),
          reason: 'the withholding must be visible, not an empty field a '
              'reader mistakes for a decode bug');
      expect(printed, contains('jon'),
          reason: 'the username is not a secret and a log line that names '
              'nobody is a log line nobody can act on');
    });

    test('round-trips, and omits an absent station rather than sending null',
        () {
      const params = SessionLoginParams(username: 'jon', password: _secret);
      final json = params.toJson();
      expect(json.containsKey('station'), isFalse,
          reason: 'encoders omit absent optionals — the library rule, so an '
              'unlabelled panel sends the same frame shape every build sent');
      final decoded = SessionLoginParams.fromJson(json);
      expect(decoded.username, 'jon');
      expect(decoded.password, _secret,
          reason: 'toJson must carry it — the far end has to receive it; '
              'only toString withholds');
      expect(decoded.station, isNull);

      final labelled = SessionLoginParams.fromJson(
          const SessionLoginParams(
                  username: 'jon', password: _secret, station: 'PACK-02')
              .toJson());
      expect(labelled.station, 'PACK-02');
    });
  });

  group('SessionLoginResult', () {
    test('round-trips the verified user and the group set', () {
      const user = AuthenticatedUser(
          username: 'rig-panel-eng',
          roleName: 'Line Panel',
          stationAccount: true);
      final result = SessionLoginResult(
          user: user,
          groups: const {AccessGroup.operate, AccessGroup.configure});
      final decoded = SessionLoginResult.fromJson(result.toJson());
      expect(decoded.user, user,
          reason: 'AuthenticatedUser has value equality; the row must arrive '
              'whole — it is what the panel renders as who signed in');
      expect(decoded.groups,
          const {AccessGroup.operate, AccessGroup.configure});
    });

    test('an unknown group name is dropped on decode, never a throw', () {
      const user =
          AuthenticatedUser(username: 'jon', roleName: 'Engineering');
      final json = SessionLoginResult(
              user: user, groups: const {AccessGroup.operate})
          .toJson();
      json['groups'] = '["operate","group_from_a_newer_build"]';
      final decoded = SessionLoginResult.fromJson(json);
      expect(decoded.groups, const {AccessGroup.operate},
          reason: 'accessGroupsFromWire\'s forgiving rule: "not granted" is '
              'the safe reading of a group this build cannot evaluate');
    });

    test('toString never carries a credential because the shape cannot hold '
        'one', () {
      const user = AuthenticatedUser(username: 'jon', roleName: 'Eng');
      final printed = SessionLoginResult(
          user: user, groups: const {AccessGroup.operate}).toString();
      expect(printed, isNot(contains(_secret)));
    });
  });

  group('the spellings both ends match on', () {
    test('the method names, as bare literals', () {
      // Bare strings on purpose — a literal spelled with the constant would
      // agree with a rename of the wire name and assert nothing about it.
      expect(Methods.sessionLogin, 'session.login');
      expect(Methods.sessionLogout, 'session.logout');
    });

    test('the hello account capability key', () {
      expect(HelloCapabilities.account, 'account');
    });

    test('the refusal markers are distinct — a panel switches on them', () {
      final markers = {
        SessionAuthMarkers.awaitingSignIn,
        SessionAuthMarkers.badCredentials,
        SessionAuthMarkers.userSourceUnavailable,
        SessionAuthMarkers.stationCredentialSession,
        SessionAuthMarkers.alreadySignedIn,
        SessionAuthMarkers.signInNotServed,
      };
      expect(markers.length, 6,
          reason: 'two markers spelling one string would make two panel '
              'renderings unreachable');
      expect(SessionAuthMarkers.awaitingSignIn, 'awaiting_sign_in',
          reason: 'increment A already put this literal on the wire in the '
              'gate\'s refusal message; the constant must match it or the '
              'panels that grep for it go blind');
    });

    test('accessGroupsToWire is accessGroupsFromWire\'s inverse, in '
        'declaration order', () {
      final wire = accessGroupsToWire(
          const {AccessGroup.configure, AccessGroup.operate});
      expect(accessGroupsFromWire(wire),
          const {AccessGroup.operate, AccessGroup.configure});
      expect(accessGroupsToWire(const <AccessGroup>{}), '[]');
    });
  });
}

@TestOn('vm')

/// `session.login` over a real socket — increment B of the 2026-09-08 ruling,
/// and the fix for the photographed defect: *nobody could sign in on a
/// gateway panel at all*, because 17-12 relayed the access stores and left
/// authentication behind on a Postgres connection the panel no longer holds.
///
/// The properties, in the order the arms drive them:
///
///  1. **Authorisation is enforced server-side.** A person's username and
///     password cross the wire; the SERVER verifies them through the
///     `AuthProvider` seam and answers with the resolved user + role +
///     groups. The panel decides nothing. The identity assignment ELEVATES
///     the session from anonymous, so it may then do what the role grants —
///     the direct-mode transition, not a relay-only one.
///  2. **Fail closed, in every direction.** Bad credentials leave the session
///     anonymous. A verifier throw leaves it in place AND is
///     distinguishable from a wrong password (`user_source_unavailable` vs
///     `bad_credentials`) — a database blip must not read as somebody
///     mistyping. A gateway composed without a verifier refuses by name.
///  3. **Never the password, anywhere.** The FIX 2 sweep from
///     `policy_access_gate_test.dart`, applied to this method: a distinctive
///     secret is driven through every refusal path and asserted absent from
///     the thrown message and from every field of every audit row.
///  4. **One identity per session.** A second login is refused the way a
///     second hello is; a station-credential session is refused by name
///     (signing a person in OVER a station base identity is elevation
///     semantics, deferred by design §5). The re-check-after-the-await
///     discipline holds for two logins racing through a slow verifier.
///  5. **The sweep judges signed-in people.** Demote or delete the account
///     in the database and the live session closes with 4001 on the next
///     poll tick — ACCESS-01 surviving the WebSocket, not switched off by it.
///  6. **`session.logout` returns the session to the anonymous identity it
///     was admitted as** — which IS the direct-mode-shaped anonymous now, and
///     holds what that holds — and is idempotent on a session that is already
///     nobody, because the panel cannot know whether a reconnect already
///     reset the far end.
///
/// Several arms below used to prove "nobody is signed in" by showing a READ
/// was refused. A read is not refused any more, so each of them now proves it
/// with a WRITE the policy declines for want of a group. That is a stronger
/// control, not a weaker one: it measures the boundary the master system
/// draws rather than a session state only this wire ever had.
@Tags(['ws'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/auth/session_login_validator.dart';
import 'package:tfc_relay_server/src/error_codes.dart';

import 'support/ws_harness.dart';

/// FIX 2's discipline: never a plausible password, so an appearance anywhere
/// can only have come from the params object.
const _secret = 'ÞYRNIGERÐI-9000-lykilorð';

const _engineer = AuthenticatedUser(
    username: 'jon', roleName: 'Engineering', stationAccount: false);

/// A verifier a case can steer: per-username passwords, an optional trap
/// that throws (the unreachable-database case), and an optional gate a case
/// holds open to interleave two logins.
final class _FakeVerifier implements AuthProvider {
  _FakeVerifier(this.byUsername);

  final Map<String, (String, AuthenticatedUser)> byUsername;
  bool throwOnNextAttempt = false;
  Completer<void>? holdUntil;
  int attempts = 0;

  @override
  Future<AuthenticatedUser?> authenticate(
      String username, String password) async {
    attempts++;
    final gate = holdUntil;
    if (gate != null) await gate.future;
    if (throwOnNextAttempt) {
      throwOnNextAttempt = false;
      throw StateError('the user source is unreachable');
    }
    final entry = byUsername[username];
    if (entry == null) return null;
    return entry.$1 == password ? entry.$2 : null;
  }
}

final class _RecordingSink implements AuditSink {
  final rows = <AuditRecord>[];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// Every string field of [row], for the no-secret sweep — the
/// `policy_access_gate_test.dart` helper's shape.
Iterable<String> _stringFields(AuditRecord row) => [
      row.who,
      row.station,
      row.roleName,
      row.surface,
      row.itemKey,
      row.member ?? '',
      row.oldValue ?? '',
      row.newValue ?? '',
      row.groupRequired,
      row.origin,
      row.actionId,
      row.reason ?? '',
    ];

final class _UserSource {
  _UserSource(this.accounts);
  Map<String, ResolvedUser> accounts;
  ResolvedUser? resolve(String username) => accounts[username];
}

_UserSource _engineeringSource() => _UserSource({
      'jon': ResolvedUser(
          user: _engineer,
          groups: const {AccessGroup.operate, AccessGroup.configure}),
    });

_FakeVerifier _verifierFor(_UserSource source) => _FakeVerifier({
      for (final entry in source.accounts.entries)
        entry.key: (_secret, entry.value.user),
    });

/// Long enough to clear `FileTokenValidator.minTokenLength`, visibly not a
/// word anyone types by accident — `session_login_validator_test.dart`'s.
const stationTestToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';

/// A one-station token file on disk, loaded — the migration-posture delegate.
Future<FileTokenValidator> stationFileValidator(
    {required Map<String, String> tokens,
    required UserResolver accounts}) async {
  final dir = Directory.systemTemp.createTempSync('relay-session-login-ws-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(jsonEncode({
    'tokens': {
      for (final entry in tokens.entries)
        entry.key: {'username': entry.value, 'station': 'ST101'},
    },
  }));
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', file.path]);
  }
  return FileTokenValidator.load(file.path, accounts: accounts);
}

Map<String, Object?> stationHello(String token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    ).toJson();

/// Minimal per-identity fakes for the factory arm —
/// `anonymous_session_test.dart`'s shapes, private copies by house style.
AccessTemplateApi recordingTemplates() => _Templates();
AccessAdminApi recordingAdmin() => _Admin();

final class _Templates implements AccessTemplateApi {
  @override
  Future<List<AccessTemplate>> list() async => const [];
  @override
  Future<Map<String, String>> bindings() async => const {};
  @override
  Future<List<String>> keysBoundTo(String templateName) async => const [];
  @override
  Future<void> create(AccessTemplate value, {String? reason}) async {}
  @override
  Future<void> update(AccessTemplate value, {String? reason}) async {}
  @override
  Future<void> rename(String from, String to, {String? reason}) async {}
  @override
  Future<void> delete(String name, {String? reason}) async {}
  @override
  Future<void> bind(String keyName, String templateName,
      {String? reason}) async {}
  @override
  Future<void> unbind(String keyName, {String? reason}) async {}
}

final class _Admin implements AccessAdminApi {
  @override
  Future<List<AccessRole>> roles() async => const [];
  @override
  // `UserSummary`, not `AuthenticatedUser`: #471 moved the roster onto a wire
  // DTO carrying real created/last-seen dates. This fake was written on a
  // branch cut before that landed, and the two met for the first time in the
  // merge — a signature collision no conflict marker shows, because neither
  // side edited the other's line.
  Future<List<UserSummary>> listUsers() async => const [];
  @override
  Future<void> createRole(AccessRole role, {String? reason}) async {}
  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async {}
  @override
  Future<void> deleteRole(String name, {String? reason}) async {}
  @override
  Future<void> renameRole(String from, String to, {String? reason}) async {}
  @override
  Future<void> createUser(NewUserParams params) async {}
  @override
  Future<void> deleteUser(String subject, {String? reason}) async {}
  @override
  Future<void> setUserRole(String subject, String newRole,
      {String? reason}) async {}
  @override
  Future<void> setUserStationAccount(String subject, bool value,
      {String? reason}) async {}
  @override
  Future<void> setRolePages(String subject, Set<String>? pages,
      {String? reason}) async {}
  @override
  Future<void> setUserPages(String subject, Set<String>? pages,
      {String? reason}) async {}
  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async {}
}

Map<String, Object?> _login(String username, String password,
        {String? station}) =>
    SessionLoginParams(
            username: username, password: password, station: station)
        .toJson();

void main() {
  group('signing in on a session admitted as nobody', () {
    test('the server verifies, answers the resolved user + role + groups, '
        'and the gate lifts', () async {
      final source = _engineeringSource();
      final sink = _RecordingSink();
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
        audit: sink,
      );
      await fixture.ready;
      await fixture.hello();

      // The anti-vacuity control. It used to be a READ, refused by the
      // blanket gate; a read is not refused any more — anonymous may read
      // here exactly as it may at a walk-up panel — so the control is now a
      // WRITE, refused by the policy for want of a group. That is a better
      // control than the one it replaces: it measures the boundary the
      // master system actually draws, rather than a session state only this
      // wire had.
      final before = await fixture.refusal(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'a shared-config WRITE before anybody signed in');
      expect(before.code, ServerErrorCodes.forbidden);

      final raw = await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret, station: 'PACK-02'),
          what: 'the sign-in');
      final result = SessionLoginResult.fromJson(
          (raw as Map).cast<String, Object?>());
      expect(result.user, _engineer,
          reason: 'the answer is the row the SERVER resolved — the panel '
              'supplied a username and a password and nothing else');
      expect(result.groups,
          const {AccessGroup.operate, AccessGroup.configure},
          reason: 'chased user → role → groups through the account source, '
              'server-side, exactly as the token path does');

      final after = await fixture.request(DataServiceMethods.prefGetAll,
          params: const <String, Object?>{},
          what: 'the same read after the sign-in');
      expect(after, isA<Map>(),
          reason: 'the awaiting gate keys on the sentinel; a verified '
              'sign-in replaces it, so the session may now do what the '
              'role grants — graded per call by the policy decorator');

      // The trail: one login row, attributed to the verified account, at
      // the station label the panel reported, stamped relay.
      final logins =
          sink.rows.where((row) => row.itemKey == 'login').toList();
      expect(logins, hasLength(1));
      expect(logins.single.who, 'jon');
      expect(logins.single.station, 'PACK-02');
      expect(logins.single.roleName, 'Engineering');
      expect(logins.single.origin, 'relay',
          reason: 'a gateway-verified sign-in must not read as a row some '
              'panel wrote about itself');
    });

    test('a wrong password is refused with the one bad-credentials marker, '
        'audited, and the sentinel stays', () async {
      final source = _engineeringSource();
      final sink = _RecordingSink();
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
        audit: sink,
      );
      await fixture.ready;
      await fixture.hello();

      final refusal = await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', 'not-the-password'),
          what: 'a sign-in with the wrong password');
      expect(refusal.code, ServerErrorCodes.unauthorized);
      expect(refusal.message, contains(SessionAuthMarkers.badCredentials));
      expect(refusal.message,
          isNot(contains(SessionAuthMarkers.userSourceUnavailable)));

      final failed =
          sink.rows.where((row) => row.itemKey == 'login.failed').toList();
      expect(failed, hasLength(1),
          reason: 'denials are recorded — the refused attempt is the more '
              'interesting audit line');
      expect(failed.single.who, 'jon');
      expect(failed.single.origin, 'relay');

      // Fail closed: the session still holds nothing, so the policy still
      // refuses the write. A refused password must not leave a session one
      // grant better off than it started.
      final still = await fixture.refusal(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'a shared-config WRITE after a refused sign-in');
      expect(still.code, ServerErrorCodes.forbidden);
    });

    test('an unknown username reads EXACTLY like a wrong password', () async {
      final source = _engineeringSource();
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.hello();

      final unknownUser = await fixture.refusal(Methods.sessionLogin,
          params: _login('nobody-of-that-name', _secret),
          what: 'a sign-in naming no account');
      final wrongPassword = await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', 'not-the-password'),
          what: 'a sign-in with the wrong password');
      expect(unknownUser.message, wrongPassword.message,
          reason: 'two messages would let anybody at the panel enumerate '
              'which usernames exist by watching which one comes back');
    });

    test('a verifier throw is unavailable, never bad credentials — and '
        'writes NO attempt row', () async {
      final source = _engineeringSource();
      final sink = _RecordingSink();
      final verifier = _verifierFor(source);
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: verifier,
        accounts: source.resolve,
        audit: sink,
      );
      await fixture.ready;
      await fixture.hello();

      verifier.throwOnNextAttempt = true;
      final refusal = await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', _secret),
          what: 'a sign-in while the user source is down');
      expect(refusal.message,
          contains(SessionAuthMarkers.userSourceUnavailable));
      expect(refusal.message,
          isNot(contains(SessionAuthMarkers.badCredentials)),
          reason: 'telling somebody their password is wrong when the '
              'database is unreachable sends them off to reset a password '
              'that was never the problem');
      expect(sink.rows.where((row) => row.itemKey == 'login.failed'),
          isEmpty,
          reason: 'a database blip is not somebody trying to get in — '
              'LocalAuthProvider\'s null-versus-throw contract, kept over '
              'the wire');
    });

    test('a gateway composed without a verifier refuses by name', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      final refusal = await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', _secret),
          what: 'a sign-in against a gateway serving none');
      expect(refusal.message, contains(SessionAuthMarkers.signInNotServed),
          reason: 'a deployment fact, not a credential verdict — the panel '
              'must not render this as "wrong password"');
    });

    test('the secret appears in no refusal message and in no field of any '
        'audit row — every refusal path driven', () async {
      final source = _engineeringSource();
      final sink = _RecordingSink();
      final verifier = _verifierFor(source);
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: verifier,
        accounts: source.resolve,
        audit: sink,
      );
      await fixture.ready;
      await fixture.hello();

      // The secret rides the PASSWORD field only. NOT the username: the
      // trail's `who` column records what was typed into the username box
      // — the direct-mode path's documented trade (audit.dart's
      // loginFailed: untrusted input, truncated, "the password is not
      // passed anywhere near this record") — so a secret driven through
      // the username field lands in `who` by design, in both modes. What
      // must never land anywhere is the password field's value, and the
      // username's absence from REFUSAL MESSAGES is pinned separately
      // below with its own marker.
      const typedName = 'HANDRIT-username-under-test';
      final refusals = <rpc.RpcException>[
        await fixture.refusal(Methods.sessionLogin,
            params: _login(typedName, _secret),
            what: 'a wrong-credentials refusal carrying the secret in the '
                'password field'),
      ];
      verifier.throwOnNextAttempt = true;
      refusals.add(await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', _secret),
          what: 'an unavailable refusal with the secret in the password'));
      // A successful login, then a second one — the already-signed-in path.
      await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the winning sign-in');
      refusals.add(await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', _secret),
          what: 'a second sign-in on a signed-in session'));

      for (final refusal in refusals) {
        expect(refusal.message, isNot(contains(_secret)));
        expect(refusal.message, isNot(contains(typedName)),
            reason: 'the refusal is fixed text: a message that echoed the '
                'typed username would also echo a password mistyped into '
                'that box, onto a screen anybody can read');
        expect('${refusal.data}', isNot(contains(_secret)),
            reason: 'the data field travels in the same -32003 the message '
                'does — _substitute must have replaced the request');
        expect('${refusal.data}', isNot(contains(typedName)));
      }
      for (final row in sink.rows) {
        for (final field in _stringFields(row)) {
          expect(field, isNot(contains(_secret)),
              reason: 'a password in an audit row outlives every rotation '
                  'of the password itself');
        }
      }
    });

    test('two logins racing through a slow verifier: one winner, and the '
        'loser is refused with a response, never a close', () async {
      final source = _engineeringSource();
      final verifier = _verifierFor(source);
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: verifier,
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.hello();

      verifier.holdUntil = Completer<void>();
      final first = fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the first racer');
      final second = fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the second racer');
      // Both racers are now suspended inside the verifier; release them.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verifier.holdUntil!.complete();

      final outcomes = await Future.wait<Object?>([
        first.then<Object?>((v) => v, onError: (Object e) => e),
        second.then<Object?>((v) => v, onError: (Object e) => e),
      ]);
      final wins = outcomes.whereType<Map>().length;
      final losses = outcomes.whereType<rpc.RpcException>().toList();
      expect(wins, 1,
          reason: 're-check after the await: the identity is assigned once '
              'per session, however the frames interleave');
      expect(losses, hasLength(1));
      expect(losses.single.message,
          contains(SessionAuthMarkers.alreadySignedIn));
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'the loser cost itself a refusal, never the session');
    });
  });

  group('a station-credential session', () {
    test('is refused by name — elevation over a station base identity is '
        'deferred, and the refusal says where to go instead', () async {
      final source = _UserSource({
        'ST101-panel': ResolvedUser(
            user: const AuthenticatedUser(
                username: 'ST101-panel',
                roleName: 'Line Panel',
                stationAccount: true),
            groups: const {AccessGroup.operate}),
      });
      final fixture = relayFixture(
        validator: SessionLoginValidator(
            stations: await stationFileValidator(
                tokens: {stationTestToken: 'ST101-panel'},
                accounts: source.resolve),
            accounts: source.resolve),
        loginVerifier: _FakeVerifier({
          'jon': (_secret, _engineer),
        }),
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: stationHello(stationTestToken),
          what: 'a station hello through the decorator');

      final refusal = await fixture.refusal(Methods.sessionLogin,
          params: _login('jon', _secret),
          what: 'a person signing in over a station session');
      expect(refusal.message,
          contains(SessionAuthMarkers.stationCredentialSession));
      expect(refusal.message, isNot(contains(_secret)));

      // The control: the station session keeps working exactly as before.
      final answer = await fixture.request(DataServiceMethods.prefGetAll,
          params: const <String, Object?>{},
          what: 'a read from the still-working station session');
      expect(answer, isA<Map>());
    });
  });

  group('the sweep, for signed-in people', () {
    test('a database demotion closes the live session with 4001; an '
        'untouched account survives the same sweep (the live control)',
        () async {
      final source = _engineeringSource();
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.hello();
      await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the sign-in');

      // The live control: an unchanged account is not reaped.
      await fixture.server.reloadTokensIfChanged();
      await fixture.request(Methods.ping,
          what: 'a ping after a sweep over an untouched login');
      expect(fixture.observedClose.closeCode, isNull);

      // Demote: same account, same role name, one group unticked.
      source.accounts['jon'] = ResolvedUser(
          user: _engineer, groups: const {AccessGroup.operate});
      await fixture.server.reloadTokensIfChanged();
      final close =
          await fixture.awaitClose('the demoted person\'s 4001 close');
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'ACCESS-01 surviving the WebSocket: demote in app_role '
              'and the signed-in session closes on the next poll tick, '
              'exactly as a station\'s does');
    });
  });

  group('session.logout', () {
    test('returns the session to anonymous: the grants go with the person, '
        'trail says who left, and a second logout is a no-op', () async {
      final source = _engineeringSource();
      final sink = _RecordingSink();
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
        audit: sink,
      );
      await fixture.ready;
      await fixture.hello();
      await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret, station: 'PACK-02'),
          what: 'the sign-in');
      await fixture.request(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'the signed-in control — the engineer holds the group');

      await fixture.request(Methods.sessionLogout,
          params: const <String, Object?>{}, what: 'the sign-out');
      final refused = await fixture.refusal(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'the same write after the sign-out');
      expect(refused.code, ServerErrorCodes.forbidden,
          reason: 'logout returns the session to the anonymous identity it '
              'was admitted as — which is exactly a direct-mode-shaped '
              'anonymous now, and holds what that holds. The grants the '
              'person had are gone with them');

      final logouts =
          sink.rows.where((row) => row.itemKey == 'logout').toList();
      expect(logouts, hasLength(1));
      expect(logouts.single.who, 'jon');
      expect(logouts.single.origin, 'relay');

      // Idempotent: the panel cannot know whether a reconnect already
      // reset the far end.
      await fixture.request(Methods.sessionLogout,
          params: const <String, Object?>{},
          what: 'a second sign-out on a session that is already nobody');
      expect(sink.rows.where((row) => row.itemKey == 'logout'),
          hasLength(1),
          reason: 'a no-op writes no second row — there is nobody to '
              'attribute one to');
    });

    test('returns to the identity the session was ADMITTED as, not a freshly '
        'minted one — a sign-out may not re-read the grants', () async {
      // The only arm where the two are distinguishable, and it needs an
      // anonymous set that is both non-empty and *changing*: with the empty
      // default they are the same object's worth of nothing.
      //
      // What it pins: policy is static per session (`key_policy.dart` — only
      // a close moves it), and a logout is not a close. An operator who edits
      // the `Operator` row mid-shift changes what the NEXT anonymous hello
      // holds. If a logout re-read the row instead, one session would silently
      // pick up an edit every other live session had not, and it would do so
      // in whichever direction the edit went — a widening included.
      var anonymousGroups = const {AccessGroup.configure};
      final source = _engineeringSource();
      final fixture = relayFixture(
        validator: SessionLoginValidator(
            accounts: source.resolve, anonymous: () => anonymousGroups),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.hello();

      // Admitted holding `configure`, so the graded write lands.
      await fixture.request(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'the anonymous control before any sign-in');

      await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the sign-in');
      // The row is narrowed while somebody is signed in.
      anonymousGroups = const {};
      await fixture.request(Methods.sessionLogout,
          params: const <String, Object?>{}, what: 'the sign-out');

      await fixture.request(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{"nodes":{}}'},
          what: 'the same write after the sign-out');
    });

    test('a station-credential session has nothing to sign out, and is told '
        'so by name', () async {
      final source = _UserSource({
        'ST101-panel': ResolvedUser(
            user: const AuthenticatedUser(
                username: 'ST101-panel',
                roleName: 'Line Panel',
                stationAccount: true),
            groups: const {AccessGroup.operate}),
      });
      final fixture = relayFixture(
        validator: SessionLoginValidator(
            stations: await stationFileValidator(
                tokens: {stationTestToken: 'ST101-panel'},
                accounts: source.resolve),
            accounts: source.resolve),
        accounts: source.resolve,
      );
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: stationHello(stationTestToken),
          what: 'a station hello');
      final refusal = await fixture.refusal(Methods.sessionLogout,
          params: const <String, Object?>{},
          what: 'a logout on a station session');
      expect(refusal.message,
          contains(SessionAuthMarkers.stationCredentialSession),
          reason: 'its identity came from hello and lives as long as the '
              'socket — a logout that stranded it below its own credential '
              'would dark-screen a wall panel');
    });
  });

  group('who the hello answer says this session is', () {
    test('a station hello carries the verified account; a credential-less '
        'one carries none', () async {
      final source = _UserSource({
        'ST101-panel': ResolvedUser(
            user: const AuthenticatedUser(
                username: 'ST101-panel',
                roleName: 'Line Panel',
                stationAccount: true),
            groups: const {AccessGroup.operate}),
      });
      final withToken = relayFixture(
        validator: SessionLoginValidator(
            stations: await stationFileValidator(
                tokens: {stationTestToken: 'ST101-panel'},
                accounts: source.resolve),
            accounts: source.resolve),
        accounts: source.resolve,
      );
      await withToken.ready;
      final raw = await withToken.request(Methods.hello,
          params: stationHello(stationTestToken), what: 'a station hello');
      final hello =
          HelloResult.fromJson((raw as Map).cast<String, Object?>());
      expect(hello.capabilities[HelloCapabilities.account], 'ST101-panel',
          reason: 'the verified username is what the attribution row on '
              'the panel should print — the rig rendered a bare container '
              'id because this was unknowable client-side');

      final anonymous =
          relayFixture(validator: SessionLoginValidator());
      await anonymous.ready;
      final nobody = await anonymous.hello();
      expect(
          nobody.capabilities.containsKey(HelloCapabilities.account), isFalse,
          reason: 'nobody is not an account, and printing the sentinel\'s '
              'self-naming string as one would be the lie the sentinel\'s '
              'names exist to prevent');
    });
  });

  group('the per-identity access families', () {
    test('are built exactly once, at login, for the verified identity',
        () async {
      final source = _engineeringSource();
      final built = <StationIdentity>[];
      final fixture = relayFixture(
        validator: SessionLoginValidator(accounts: source.resolve),
        loginVerifier: _verifierFor(source),
        accounts: source.resolve,
        accessFor: (identity) {
          built.add(identity);
          return (
            accessTemplates: recordingTemplates(),
            accessAdmin: recordingAdmin(),
            backendConfig: null,
          );
        },
      );
      await fixture.ready;
      await fixture.hello();
      expect(built.map((identity) => identity.user.username),
          [StationIdentity.anonymousWho],
          reason: 'built for anonymous at hello now — its audit rows '
              'attribute to `anonymous`, the same string direct mode writes '
              'for the same state, so one action lands in one trail '
              'whichever transport made it');
      await fixture.request(Methods.sessionLogin,
          params: _login('jon', _secret), what: 'the sign-in');
      expect(built.map((identity) => identity.user.username),
          [StationIdentity.anonymousWho, 'jon'],
          reason: 'the factory constructs stores whose audit rows attribute '
              'to the identity it was called with — that identity now '
              'exists, and it is the verified person');
    });
  });
}

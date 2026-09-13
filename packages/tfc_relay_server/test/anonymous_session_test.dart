@TestOn('vm')

/// A session admitted with no credential is the **anonymous identity**, graded
/// by the one `AccessPolicy` — not a third state that may do nothing but wait.
///
/// ## What this replaces, and why
///
/// `awaiting_sign_in_test.dart` pins the state this file deletes: a blanket,
/// method-level refusal of everything but four names. It was fail-closed and
/// it was reasonable, and it had one consequence nobody costed — **it bypasses
/// the policy entirely**, so it cannot be reasoned about in the same terms as
/// a not-signed-in panel in direct mode. There is no counterpart to it there.
///
/// Measured on the rig, 2026-09-09, against the live backend:
///
///  * a credential-less hello IS admitted — a session id comes back, with no
///    `account` capability;
///  * `session.login` IS reachable on it, and answers `bad_credentials` to a
///    wrong password;
///  * `preferences.getString('key_mappings')` is REFUSED `awaiting_sign_in`;
///  * `subscribe` is REFUSED `awaiting_sign_in`;
///  * a station token makes it all work, and then `session.login` is refused
///    `station_credential_session` — so the token is not a way out, and the
///    server itself says to remove it.
///
/// A panel therefore could not boot: it reads `key_mappings` in order to build
/// its client, and it cannot sign in until it has booted.
///
/// ## The claim, in one line
///
/// **Nothing here opens the socket.** Preference reads were already ungated on
/// this wire by design — `policy_state_man.dart`'s `_PolicyPreferences.
/// getString` is a straight passthrough, and its doc says "anyone
/// authenticated may read them" — and `canSee` ships all-visible. What the
/// blanket gate added on top was a second, method-shaped rule that the policy
/// never saw. Deleting it makes the two transports answer the same question
/// the same way; every refusal below is the **policy's**, made server-side,
/// naming the group it wanted.
///
/// ## What anonymous holds here, and the line this file does not cross
///
/// The identity's group set is **injected** and defaults to empty. That is the
/// deliberate first increment: with an empty set, every write question on this
/// wire answers no, and the only thing that changes is that reads stop being
/// refused by a rule the policy never made. Sourcing the set from the
/// `Operator` row — which is what direct mode's `anonymousGroups()` does, and
/// which would grant `operate`, and with it plant writes, to anything that can
/// reach the port — is a separate decision with a plant-wide blast radius, and
/// it is not made in this file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/session_login_validator.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_stateman_contract/testing/fake_data_services.dart';

import 'support/ws_harness.dart';

const _stationOneToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';

/// The rig panel's own boot key, and the size of it, so the arm below is about
/// the thing that actually failed rather than about a toy row.
const _keyMappings = 'key_mappings';

/// A tag the fake source actually serves, so a refusal below is the POLICY's
/// and not `unknownKey` — the visibility answer is raised first, and a test
/// that wrote to a key nothing serves would pass while proving nothing.
const _plantKey = 'CN01.MOT01.speed';

final class _UserSource {
  _UserSource(this.accounts);
  Map<String, ResolvedUser> accounts;
  ResolvedUser? resolve(String username) => accounts[username];
}

_UserSource _seedUsers() => _UserSource({
      'ST101-panel': ResolvedUser(
          user: const AuthenticatedUser(
              username: 'ST101-panel',
              roleName: 'Line Panel',
              stationAccount: true),
          groups: const {AccessGroup.operate}),
    });

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('relay-anonymous-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

String _writeTokenFile(Directory dir) {
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(jsonEncode({
    'tokens': {
      _stationOneToken: {'username': 'ST101-panel', 'station': 'ST101'},
    },
  }));
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', file.path]);
  }
  return file.path;
}

Future<SessionLoginValidator> _wrappedValidator(_UserSource users) async =>
    SessionLoginValidator(
        stations: await FileTokenValidator.load(_writeTokenFile(_tempDir()),
            accounts: users.resolve));

Map<String, Object?> _helloWithToken(String token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    ).toJson();

/// Every name a client can *call* on this wire, from the declared sets plus
/// the core table `relay_session.dart` registers by hand — the same union
/// `method_table_closed_test.dart` closes over.
Set<String> _callableMethods() => {
      Methods.hello,
      Methods.ping,
      Methods.sessionLogin,
      Methods.sessionLogout,
      Methods.subscribe,
      Methods.unsubscribe,
      Methods.write,
      Methods.writeStatus,
      Methods.ackAlarm,
      Methods.read,
      Methods.readFresh,
      Methods.readMany,
      ...DataServiceMethods.all,
      ...AccessMethods.all,
    };

void main() {
  group('the boot deadlock, at the server', () {
    test(
        'a credential-less session may READ the boot key — this is the rig '
        'failure, and it is a read the policy never refused', () async {
      final prefs = FakePreferences();
      await prefs.setString(_keyMappings, '{"nodes":{}}');
      final fixture = relayFixture(
          validator: SessionLoginValidator(), preferences: prefs);
      await fixture.ready;
      await fixture.hello();

      final value = await fixture.request(
        DataServiceMethods.prefGetString,
        params: const {'key': _keyMappings},
        what: 'the boot key read by a panel nobody has signed in on',
      );

      expect(value, '{"nodes":{}}',
          reason: 'a panel reads key_mappings in ORDER TO BUILD its client, '
              'and it cannot sign in until it has booted. Refusing this is '
              'the ring the rig measured — and the refusal was never the '
              'policy\'s: preference reads are a straight passthrough '
              '(policy_state_man.dart\'s _PolicyPreferences.getString)');
    });

    test('and it may subscribe — reads are ungated on this wire by design, on '
        'both transports', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();

      await fixture.request(
        Methods.subscribe,
        params: const SubscribeParams(sub: 'page-1', keys: [_plantKey]).toJson(),
        what: 'a subscribe from a session nobody has signed in on',
      );
    });
  });

  group('what anonymous may NOT do is refused BY THE POLICY, server-side', () {
    test(
        'writing the boot key is refused — key_mappings takes configure, and '
        'the refusal names that rather than a method-level state', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();

      final refusal = await fixture.refusal(
        DataServiceMethods.prefSetString,
        params: const {'key': _keyMappings, 'value': '{"nodes":{}}'},
        what: 'a boot-key WRITE from a session nobody has signed in on',
      );

      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'the whole point: the server still refuses, and it refuses '
              'through the one AccessPolicy — 518 KiB of plant routing '
              'config is not something an unauthenticated peer re-points');
      expect(refusal.message, isNot(contains('awaiting_sign_in')),
          reason: 'the third state is gone; a refusal that still named it '
              'would be the blanket gate surviving under another name');
    });

    test('and so is a plant write, while anonymous holds nothing', () async {
      // The group set is injected and empty here. This arm is what makes
      // "reads opened, writes did not" a measured claim rather than a hope,
      // and it is the arm that CHANGES if the Operator row is ever wired in
      // as anonymous's groups — see this file's header.
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      // Served, so the refusal below is the POLICY's. An unserved key is
      // answered `unknownKey` first — deliberately, so a hidden tag cannot be
      // enumerated by asking — and a case that wrote to one would pass while
      // proving nothing.
      fixture.served.setValue(_plantKey, 1200);
      await fixture.hello();

      final refusal = await fixture.refusal(
        Methods.write,
        params: const {
          'key': _plantKey,
          'value': 12.5,
          'cmd': 'anon-write-1',
        },
        what: 'a plant write from a session nobody has signed in on',
      );

      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'an unauthenticated socket peer must not actuate the '
              'plant. groupForTag floors an unbound key at operate, and '
              'anonymous holds no groups on this increment');
    });
  });

  group('sign-in is the direct-mode transition, not a new one', () {
    test('session.login is still reachable on an anonymous session', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();

      // No verifier is wired here, so the handler's own deployment refusal is
      // the proof it was REACHED — the same observation
      // `awaiting_sign_in_test.dart` made, and it must survive the gate's
      // deletion.
      final login = await fixture.refusal(
        Methods.sessionLogin,
        params: const {'username': 'jon', 'password': 'irrelevant'},
        what: 'a login against a verifier-less gateway',
      );
      expect(login.message, contains('sign_in_not_served'));
      expect(login.message, isNot(contains('awaiting_sign_in')));
    });

    test('a station-credential session is unchanged — it was never anonymous',
        () async {
      final users = _seedUsers();
      final fixture = relayFixture(validator: await _wrappedValidator(users));
      await fixture.ready;
      fixture.served.setValue(_plantKey, 1200);
      await fixture.request(Methods.hello,
          params: HelloParams(
            protocol: protocolVersion,
            supported: const [protocolVersion],
            client: const PeerInfo('panel-under-test', '0.1.0'),
            token: _stationOneToken,
          ).toJson(),
          what: 'a hello carrying a station credential');

      // The control that keeps the arms above honest: if the change had
      // simply removed grading rather than re-pointed it, a station session
      // would behave identically to an anonymous one and every arm here
      // would pass vacuously. A station holds `operate`, so its plant write
      // is ALLOWED where anonymous's was refused.
      await fixture.request(
        Methods.write,
        params: const {
          'key': _plantKey,
          'value': 12.5,
          'cmd': 'station-write-1',
        },
        what: 'a plant write from a station-credential session',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Migrated from `awaiting_sign_in_test.dart`, which pinned the state this
  // change deletes. Its arms fall into two kinds and both are here: the ones
  // that were about the *credential-less admission* (still true, still worth a
  // guard) and the ones that were about the *blanket gate* (inverted, because
  // the gate is what went).
  // ---------------------------------------------------------------------------

  group('the credential-less admission itself, unchanged', () {
    test('a hello with no credential completes the handshake', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      final result = await fixture.hello();
      expect(result.protocol, protocolVersion,
          reason: 'anti-vacuity for every arm in this file: a hello that '
              'never completed would make each of them true of a session '
              'that was never admitted at all');
      expect(fixture.server.sessions.sessionCount, 1);
    });

    test('the hello answer carries no account — anonymous is not one',
        () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      final raw = await fixture.request(Methods.hello,
          params: helloParams(), what: 'the hello answer');
      expect((raw as Map)['capabilities'],
          isNot(contains(HelloCapabilities.account)),
          reason: 'a panel that printed `anonymous` in its attribution prose '
              'would be naming a user nobody authenticated as');
    });

    test('survives the revocation sweep, in both spellings — and '
        'reloadTokensIfChanged accepts the decorator', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      await fixture.server.reloadTokens();
      expect(await fixture.server.reloadTokensIfChanged(), isFalse);
      await fixture.request(Methods.ping,
          what: 'a ping after two sweeps over an anonymous session');
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'a sweep that reaped panels at the sign-in screen would '
              'close every idle station once per poll tick');
    });

    test('a station demoted in the database is still retired with 4001 — the '
        'change must not cost the revocation property', () async {
      final users = _seedUsers();
      final fixture = relayFixture(validator: await _wrappedValidator(users));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWithToken(_stationOneToken),
          what: 'a station hello through the decorator');
      users.accounts['ST101-panel'] = ResolvedUser(
          user: const AuthenticatedUser(
              username: 'ST101-panel',
              roleName: 'Line Panel',
              stationAccount: true),
          groups: const <AccessGroup>{});
      expect(await fixture.server.reloadTokensIfChanged(), isFalse,
          reason: 'the file did not change; the demotion is the database\'s');
      final close = await fixture.awaitClose(
          'the demoted station\'s close through the decorator');
      expect(close.closeCode, CloseCodes.authExpired);
    });
  });

  group('the blanket gate is gone, and cannot come back quietly', () {
    test('NO callable method is refused by a state outside the policy — the '
        'whole table swept', () async {
      // The inversion of the old partition arm, and the sabotage guard for
      // this whole change: that arm swept the table asserting every method
      // carried `awaiting_sign_in`; this one sweeps the same table asserting
      // none does. A reintroduced method-level gate — under any name, for any
      // subset — reddens here rather than being discovered on a panel that
      // will not boot.
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      final methods = _callableMethods()..remove(Methods.hello);
      expect(methods.length, greaterThan(60),
          reason: 'the sweep must be the whole table; a shrunken union '
              'passes by visiting nothing');
      for (final method in methods) {
        try {
          await fixture.request(method,
              params: const <String, Object?>{}, what: method);
        } on rpc.RpcException catch (error) {
          expect(error.message, isNot(contains('awaiting_sign_in')),
              reason: '$method still carries the deleted third state. Every '
                  'refusal on this wire must be the policy\'s, naming the '
                  'group it wanted — or a decode/plumbing answer — never a '
                  'session state the master system cannot see');
        }
      }
    });

    test('the gateway\'s preference vocabulary IS announced now', () async {
      // Inverted deliberately, and it is a consequence rather than a
      // relaxation chosen on its own: the drop existed because an
      // unauthenticated session could not read a preference at all, so naming
      // a changed key disclosed a vocabulary it had no other way to see. It
      // can read them now — the policy says so, on both transports — and
      // withholding the notification would leave a panel holding a stale
      // `key_mappings` with no way to learn it.
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      await fixture.served.preferences.setString(_keyMappings, '{"a":1}');
      await fixture.request(Methods.ping, what: 'a barrier ping');
      final announced = fixture.inbound.where((frame) {
        final decoded = jsonDecode(frame);
        return decoded is Map &&
            decoded['method'] == DataServiceMethods.preferencesChanged;
      });
      expect(announced, isNotEmpty,
          reason: 'this is the reload path a panel depends on to notice its '
              'boot key moved');
    });

    test('the per-identity access families ARE built for anonymous', () async {
      final built = <StationIdentity>[];
      final fixture = relayFixture(
        validator: SessionLoginValidator(),
        accessFor: (identity) {
          built.add(identity);
          return (
            accessTemplates: _Templates(),
            accessAdmin: _Admin(),
            backendConfig: null,
          );
        },
      );
      await fixture.ready;
      await fixture.hello();
      expect(built, hasLength(1),
          reason: 'leaving this null refused the access family by NAME, '
              'which is the method-shaped refusal outside the policy this '
              'change removes — and it is what stopped a booting panel '
              'reading its access templates');
      expect(built.single.isAnonymous, isTrue);
      expect(built.single.user.username, StationIdentity.anonymousWho,
          reason: 'the trail spelling has to match direct mode\'s, or one '
              'column holds two vocabularies for one state');
    });
  });
}

/// Minimal per-identity fakes for the factory arm, copied from
/// `session_identity_test.dart`'s shapes.
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

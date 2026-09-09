@TestOn('vm')

/// The awaiting-sign-in gate, over a real socket: a session admitted with no
/// credential may do **nothing** until somebody signs in.
///
/// `SessionLoginValidator` (see `session_login_validator_test.dart`) is only
/// half of increment A. The sentinel identity it mints carries the empty
/// group set, but the empty set alone is not fail-closed on this wire:
/// `canSee` is deliberately ungated (§11's read deferral), so a session
/// graded only by groups could still photograph the plant — every tag value,
/// every preference, the browse tree. The other half is therefore a
/// session-level gate at `_gated`, the same single choke point the handshake
/// gate uses, refusing every method but liveness while the identity is the
/// sentinel.
///
/// The arms:
///
///  1. **Anti-vacuity first**: a credential-less hello genuinely completes
///     the handshake — the gate below is a gate on a session that exists.
///  2. **The whole method table is refused**, swept from the declared sets
///     rather than listed by hand, so a method added next year is covered on
///     the day it lands.
///  3. **`ping` still answers** — the session is waiting, not broken.
///  4. **A station-token session through the same decorator is not gated** —
///     the gate keys on the sentinel, never on which validator did the
///     admitting. Without this control, a gate that refused everything for
///     everyone would pass arm 2.
///  5. **The revocation sweep leaves the sign-in screen alone**, both sweep
///     spellings — and `reloadTokensIfChanged` accepts the decorator, so
///     the backend's existing poll (17-11) keeps working the day the
///     composition wraps its file validator.
///  6. **A demoted station is still retired through the decorator**, end to
///     end over the socket: the ruling must not cost the 4001 property.
///  7. **The gateway's preference vocabulary is not announced to nobody**:
///     the `preferences.changed` notification is withheld from an awaiting
///     session, for the same reason it is withheld pre-hello.
///  8. **The per-identity access families are not built for nobody**: the
///     `accessFor` factory is a construction attributed to an identity, and
///     the sentinel is not one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/auth/session_login_validator.dart';
import 'package:tfc_relay_server/src/error_codes.dart';

import 'support/ws_harness.dart';

const _stationOneToken = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';

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
  final dir = Directory.systemTemp.createTempSync('relay-awaiting-');
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

/// The methods the awaiting gate exempts, and there may never be a fifth.
///
/// **This literal is the security boundary of the credential-less
/// admission**, written out by hand so widening it is an edit a reviewer
/// reads: everything an unauthenticated socket can do, it can do through
/// these four names. `hello` because the first one runs while the identity
/// is still null; `ping` because a panel at the sign-in screen is waiting,
/// not broken; the two session-auth names because they are what the
/// awaiting state exists FOR — the login is how it ends, and the logout is
/// idempotent on nobody. The partition arm below fails in BOTH directions:
/// a fifth method silently joining the exemption (answered, or refused
/// under any other marker, when it should carry `awaiting_sign_in`), and
/// one of these four falling back under the gate.
Set<String> _exemptFromAwaitingGate() => {
      Methods.hello,
      Methods.ping,
      Methods.sessionLogin,
      Methods.sessionLogout,
    };

void main() {
  group('a session admitted with no credential', () {
    test('completes the handshake — the gate below gates a session that '
        'exists', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      final result = await fixture.hello();
      expect(result.protocol, protocolVersion,
          reason: 'anti-vacuity for every refusal below: a hello that never '
              'completed would make "everything is refused" true of a '
              'session that was never admitted at all');
      expect(fixture.server.sessions.sessionCount, 1);
    });

    test('is refused every callable method except EXACTLY the four exempt '
        'names — the partition swept from the whole table', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      final exempt = _exemptFromAwaitingGate();
      expect(exempt, hasLength(4),
          reason: 'the exemption list is the security boundary of the '
              'credential-less admission; a fifth name is a decision, '
              'never a drift');
      final methods = _callableMethods().difference(exempt);
      expect(methods.length, greaterThan(60),
          reason: 'the sweep must be the whole table; a shrunken union '
              'passes by visiting nothing');
      for (final method in methods) {
        final refusal = await fixture.refusal(method,
            params: const <String, Object?>{},
            what: '$method against a session nobody signed in on');
        expect(refusal.code, ServerErrorCodes.unauthorized,
            reason: '$method must be refused as unauthorized while nobody '
                'has signed in — not answered, not helloRequired (the '
                'handshake did complete), and not method-not-found');
        expect(refusal.message, contains('awaiting_sign_in'),
            reason: 'the marker is what tells a panel to show the sign-in '
                'screen rather than an error toast');
      }
    });

    test('the four exempt names are genuinely reachable while awaiting — '
        'the other half of the partition, so the exemption list cannot '
        'rot in either direction', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();

      // ping answers.
      await fixture.request(Methods.ping,
          what: 'a ping from a session awaiting sign-in');
      // session.logout answers: idempotent on nobody.
      await fixture.request(Methods.sessionLogout,
          params: const <String, Object?>{},
          what: 'a logout on a session that is already nobody');
      // session.login REACHES ITS HANDLER: this fixture serves no verifier,
      // so the refusal is sign_in_not_served — a deployment fact from
      // inside the handler, and NOT the awaiting marker the gate would
      // have thrown before it.
      final login = await fixture.refusal(Methods.sessionLogin,
          params: const {'username': 'jon', 'password': 'irrelevant'},
          what: 'a login against a verifier-less gateway');
      expect(login.message, contains('sign_in_not_served'));
      expect(login.message, isNot(contains('awaiting_sign_in')),
          reason: 'a login refused by the awaiting gate itself would be a '
              'sign-in screen no one can ever get past');
      // A second hello is the GATE's already_helloed refusal — reachable,
      // just spent.
      final second = await fixture.refusal(Methods.hello,
          params: helloParams(),
          what: 'a second hello from an awaiting session');
      expect(second.message, isNot(contains('awaiting_sign_in')));
    });

    test('may still ping: the session is waiting, not broken', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      await fixture.request(Methods.ping,
          what: 'a ping from a session awaiting sign-in');
    });

    test('survives the revocation sweep, in both spellings — and '
        'reloadTokensIfChanged accepts the decorator', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      await fixture.server.reloadTokens();
      expect(await fixture.server.reloadTokensIfChanged(), isFalse,
          reason: 'no station file is wrapped, so nothing can have changed '
              '— and the call must not throw, or the backend poll dies on '
              'its first tick the day the composition wraps its validator');
      // The sweep ran twice; the sign-in screen is still there.
      await fixture.request(Methods.ping,
          what: 'a ping after two sweeps over an awaiting session');
      expect(fixture.observedClose.closeCode, isNull,
          reason: 'a sweep that reaped panels at the sign-in screen would '
              'close every idle station once per poll tick');
    });

    test('is not told the gateway\'s preference vocabulary', () async {
      final fixture = relayFixture(validator: SessionLoginValidator());
      await fixture.ready;
      await fixture.hello();
      await fixture.served.preferences.setString('key_mappings', '{"a":1}');
      // The barrier `preferences_notify_test.dart` uses: answers and
      // notifications share the FIFO priority lane, so anything queued by
      // the set above is on the client by the time this answers.
      await fixture.request(Methods.ping, what: 'a barrier ping');
      final announced = fixture.inbound.where((frame) {
        final decoded = jsonDecode(frame);
        return decoded is Map &&
            decoded['method'] == DataServiceMethods.preferencesChanged;
      });
      expect(announced, isEmpty,
          reason: 'preference keys are the gateway\'s configuration '
              'vocabulary — key_mappings names itself — and announcing '
              'them to a socket nobody signed in on is a disclosure '
              'nothing else on this wire makes');
    });

    test('gets no per-identity access families built for it', () async {
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
      expect(built, isEmpty,
          reason: 'the factory constructs stores whose audit rows attribute '
              'to the identity it was called with, and the sentinel is '
              'nobody — a construction for nobody is D-11\'s false '
              'attribution waiting for a caller');
    });
  });

  group('a station-token session through the same decorator', () {
    test('is not gated: the gate keys on the sentinel, not on the validator',
        () async {
      final fixture =
          relayFixture(validator: await _wrappedValidator(_seedUsers()));
      await fixture.ready;
      final raw = await fixture.request(Methods.hello,
          params: _helloWithToken(_stationOneToken),
          what: 'a station hello through the decorator');
      expect((raw as Map)['protocol'], protocolVersion);
      final answer = await fixture.request(DataServiceMethods.prefGetAll,
          params: const <String, Object?>{},
          what: 'a preference read from a station the file admitted');
      expect(answer, isA<Map>(),
          reason: 'the control that keeps arm 2 honest: a gate that refused '
              'everything for everyone would sweep clean and break every '
              'panel still on a token file mid-migration');
    });

    test('is still retired by a database demotion, end to end — the ruling '
        'must not cost the 4001 property', () async {
      final users = _seedUsers();
      final fixture =
          relayFixture(validator: await _wrappedValidator(users));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWithToken(_stationOneToken),
          what: 'a station hello through the decorator');
      // Demote in the database: same account, same role name, the group
      // unticked — the file untouched, exactly 17-11's measured case.
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
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'demote in app_role and the live session closes with '
              '4001 — measured before this change, and it must stay '
              'measured after it');
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
  Future<void> setUserPassword(SetUserPasswordParams params) async {}
}

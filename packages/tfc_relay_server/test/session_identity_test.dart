@TestOn('vm')

/// The identity's whole life on one session (17-09): minted once and never
/// replaced, revoked when the database narrows what it means, and refused
/// outright when the gateway has a token file and nobody wired the account
/// resolver that gives the tokens meaning.
///
/// ## What each group here leans on
///
///  * **Once only** — 16-03 fixed the batched-`hello` race in `_hello` itself
///    (the re-check after the await); `concurrent_hello_test.dart` owns the
///    race in both shapes. The arms here assert the *property* — sequential
///    and batched, one identity — and cite 16-03 so the two are never
///    re-derived independently. Sabotage (d) of this plan removes the
///    once-only guard and both halves must redden together.
///  * **Revocation on demotion** — D-08. Under the user model (17-04b) the
///    role and its groups live in the database, so the sweep consults the
///    live `UserResolver` and the file digest cannot see a demotion. That is
///    why `reloadTokensIfChanged` sweeps even when the bytes are unchanged:
///    the digest guards the parse, not the credential.
///  * **No resolver, no gateway** — D-06's third fail-closed leg. A token
///    file with no `UserResolver` behind it is a list of usernames nobody
///    can grade, and `FileTokenValidator`'s own reasoning about a misspelled
///    PEM applies verbatim: a gateway that admitted every panel because
///    somebody forgot a constructor argument would look perfectly healthy
///    from every screen in the plant.
///  * **The sink survives composition** — D-05 through 17-07 built the
///    ledger against a directly-constructed `PolicyStateMan`; Phase 10's
///    CR-01 is the standing reason that is not enough ("a composition
///    nothing assembles is a composition nothing tests"), so the arm here
///    measures the rows through `RelayServer`.
///
/// One deliberate divergence from the 17-09 plan text, argued rather than
/// slipped in: the plan asks that a **widened** role not close the session.
/// 17-04b landed the opposite and says why — "compare the account row WHOLE
/// in the sweep: any edit to who the account is retires the session", and the
/// group set is part of the credential's meaning. A widening that closed
/// nothing would be a grant that takes effect whenever the panel next feels
/// like reconnecting — the mirror image of the demotion complaint D-08
/// exists to close. So the arm asserts a widening closes too (and the panel
/// reconnects into the wider identity), while the anti-DoS half the plan is
/// really after — **an unchanged credential closes nothing** — is pinned
/// exactly as written. `stillValid` lives in `auth/`, which 17-04b owns.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/auth_config.dart';
import 'package:tfc_relay_server/src/auth/file_token_validator.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';
import 'support/ws_harness.dart';

// ---------------------------------------------------------------------------
// Stations. Users, resolved — never roles in a file.
// ---------------------------------------------------------------------------

const _tokenOne = 'ST101-1nZq4tGm7Yb2Kd8Vw6Rc0Pf3';
const _tokenTwo = 'ST201-9aXe5uHj1Lo4Nm7Bs2Tv8Qi6';

const _userOne = AuthenticatedUser(
    username: 'ST101-panel', roleName: 'Panel Operator', stationAccount: true);
const _userTwo = AuthenticatedUser(
    username: 'ST201-panel', roleName: 'Hall Display', stationAccount: true);

const _stationOne = StationIdentity(
  user: _userOne,
  station: 'ST101',
  session: AccessSession(
      user: _userOne, groups: {AccessGroup.operate, AccessGroup.configure}),
);
const _stationTwo = StationIdentity(
  user: _userTwo,
  station: 'ST201',
  session: AccessSession(user: _userTwo, groups: {AccessGroup.operate}),
);

/// Two stations, two tokens, no third answer —
/// `concurrent_hello_test.dart`'s validator, on the user model.
final class _TwoStations implements TokenValidator {
  const _TwoStations();

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      switch (params.token) {
        _tokenOne => const TokenAccepted(_stationOne),
        _tokenTwo => const TokenAccepted(_stationTwo),
        _ => const TokenRejected('this gateway issued no such credential'),
      };
}

/// An account source a case can edit underneath a live gateway — the seam
/// 17-11 fills from `AccessRepository`, filled here from a map.
final class _Accounts {
  final rows = <String, ResolvedUser>{
    'ST101-panel': const ResolvedUser(
        user: _userOne,
        groups: {AccessGroup.operate, AccessGroup.configure}),
    'ST201-panel':
        const ResolvedUser(user: _userTwo, groups: {AccessGroup.operate}),
  };

  ResolvedUser? call(String username) => rows[username];
}

/// An [AuditSink] that keeps every row — the recorder arm 7 reads.
final class _RecordingSink implements AuditSink {
  final rows = <AuditRecord>[];
  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

HelloParams _helloWith(String? token) => HelloParams(
      protocol: protocolVersion,
      supported: const [protocolVersion],
      client: const PeerInfo('panel-under-test', '0.1.0'),
      token: token,
    );

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('relay-identity-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

String _writeTokenFile(Directory dir, Map<String, Object?> tokens) {
  final file = File('${dir.path}/tokens.json');
  file.writeAsStringSync(jsonEncode({'tokens': tokens}));
  if (!Platform.isWindows) Process.runSync('chmod', ['600', file.path]);
  return file.path;
}

Map<String, Object?> _twoStationFile() => {
      _tokenOne: {'username': 'ST101-panel', 'station': 'ST101'},
      _tokenTwo: {'username': 'ST201-panel', 'station': 'ST201'},
    };

/// A production gateway over a token file and an editable account source.
RelayFixture _gateway(_Accounts accounts, String path,
        {AuditSink? audit}) =>
    relayFixture(
      config: ServerConfig(
        tick: ServerConfig.minTick,
        auth: AuthConfig(tokenFilePath: path),
      ),
      accounts: accounts.call,
      audit: audit,
    );

void main() {
  group('the identity is minted once', () {
    test('a sequential second hello is refused and the identity is unchanged',
        () async {
      final pair = channelPair();
      final api = FakeStateMan();
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: api,
        config: ServerConfig(),
        handles: HandleTable(),
        buffer: ConflatingSendBuffer(maxPending: 4096),
        validator: const _TwoStations(),
        onError: (_, __, ___) {},
      );
      final client = rpc.Client(pair.client);
      unawaited(client.listen());
      addTearDown(() async {
        await client.close();
        await session.close(1000, 'identity test over');
        await api.dispose();
      });

      await within(
          client.sendRequest(Methods.hello, _helloWith(_tokenOne).toJson()),
          'the first hello');

      Object? error;
      try {
        await within(
            client.sendRequest(Methods.hello, _helloWith(_tokenTwo).toJson()),
            'the second hello');
      } on rpc.RpcException catch (e) {
        error = e.code;
      }
      expect(error, ServerErrorCodes.alreadyHelloed);
      expect(session.identity, _stationOne,
          reason: 'the identity is the one the accepted handshake set; a '
              'second hello carrying another station\'s valid token must not '
              'move it, because it is the subject the revocation sweep '
              'judges by');
      expect(session.sentCloseCode, isNull);
    });

    test('two hellos batched into one frame leave one identity — 16-03\'s '
        'fix, held', () async {
      // The batched half is asserted explicitly and cites 16-03-SUMMARY so
      // the once-only property and the race fix are one recorded fact:
      // json_rpc_2 dispatches a batch through Future.wait, both hellos pass
      // the null guard in one turn, and only the re-check after the await
      // (relay_session._hello) keeps the loser from overwriting the field.
      final pair = channelPair();
      final api = FakeStateMan();
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: api,
        config: ServerConfig(),
        handles: HandleTable(),
        buffer: ConflatingSendBuffer(maxPending: 4096),
        validator: const _TwoStations(),
        onError: (_, __, ___) {},
      );
      addTearDown(() async {
        await session.close(1000, 'identity test over');
        await api.dispose();
      });

      final answers = <String, Map<String, Object?>>{};
      pair.client.stream.listen((frame) {
        final decoded = jsonDecode(frame);
        for (final entry in decoded is List ? decoded : [decoded]) {
          if (entry is Map && entry['id'] is String) {
            answers[entry['id'] as String] =
                entry.cast<String, Object?>();
          }
        }
      });

      Map<String, Object?> frame(String id, String token) => {
            'jsonrpc': '2.0',
            'id': id,
            'method': Methods.hello,
            'params': _helloWith(token).toJson(),
          };
      pair.client.sink
          .add(jsonEncode([frame('a', _tokenOne), frame('b', _tokenTwo)]));

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (answers.length < 2) {
        if (DateTime.now().isAfter(deadline)) {
          fail('waited 5 s for both batched hello answers; got '
              '${answers.keys.toList()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(answers['a']!.containsKey('result'), isTrue);
      expect((answers['b']!['error'] as Map)['code'],
          ServerErrorCodes.alreadyHelloed,
          reason: 'the loser of the batch is refused with a response and '
              'never a close — 16-03\'s second failure mode');
      expect(session.identity, _stationOne,
          reason: 'both hellos passed the null guard in one turn; only the '
              're-check after the await keeps the second from overwriting '
              'the identity (16-03-SUMMARY). If this is red while the '
              'sequential half is green, the guard and the re-check are '
              'covering different things and the SUMMARY must say so');
      expect(session.sentCloseCode, isNull);
    });
  });

  group('the sweep follows the database (D-08)', () {
    test('a narrowed role closes the session with 4001 — file untouched',
        () async {
      final accounts = _Accounts();
      final fixture = _gateway(accounts, _writeTokenFile(_tempDir(),
          _twoStationFile()));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenOne).toJson(), what: 'ST101\'s hello');
      expect(fixture.server.sessions.sessions.single.identity, _stationOne);

      // The demotion an operator actually performs: untick `configure` on
      // the role. No token file involved, so the digest cannot see it —
      // which is exactly why the poll's one call must still sweep.
      accounts.rows['ST101-panel'] = const ResolvedUser(
          user: _userOne, groups: {AccessGroup.operate});
      expect(await fixture.server.reloadTokensIfChanged(), isFalse,
          reason: 'the bytes did not change; the answer reports the file, '
              'and the sweep must not depend on it');

      final close = await fixture.awaitClose('the demoted station\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'a demotion that takes effect only when the operator '
              'chooses to reconnect is a demotion an operator can postpone '
              'indefinitely (D-08). 4001 observed on the client\'s own '
              'socket, the code every credential retirement carries');
    }, tags: 'ws');

    test('an unchanged credential closes nothing', () async {
      // The anti-DoS half, and the reason StationIdentity has value
      // equality: a sweep that closed every session on every reload is the
      // failure mode the identity type's own doc names.
      final accounts = _Accounts();
      final fixture = _gateway(accounts, _writeTokenFile(_tempDir(),
          _twoStationFile()));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenOne).toJson(), what: 'ST101\'s hello');

      await fixture.server.reloadTokensIfChanged();
      await fixture.server.reloadTokens();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fixture.server.sessions.sessionCount, 1,
          reason: 'nothing about the credential changed, and the session '
              'must survive both reload shapes');
      expect(await fixture.request(Methods.ping, what: 'a ping after the '
          'no-op sweeps'), isA<Map>());
    }, tags: 'ws');

    test('a widened role also retires the session — the whole-row rule, '
        'stated', () async {
      // Divergence from the plan text, argued in the library doc: 17-04b's
      // sweep compares the resolved account whole, groups included, so a
      // *grant* takes effect at the next sweep too — the panel is closed
      // with the same 4001 and reconnects into the wider identity, instead
      // of holding its narrower one until it feels like reconnecting.
      final accounts = _Accounts();
      final fixture = _gateway(accounts, _writeTokenFile(_tempDir(),
          _twoStationFile()));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenOne).toJson(), what: 'ST101\'s hello');

      accounts.rows['ST101-panel'] = const ResolvedUser(user: _userOne,
          groups: {
            AccessGroup.operate,
            AccessGroup.configure,
            AccessGroup.users
          });
      await fixture.server.reloadTokensIfChanged();

      final close = await fixture.awaitClose('the widened station\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired,
          reason: 'the group set is part of what the credential means '
              '(17-04b: "compare the account row WHOLE"); a session carrying '
              'a stale meaning is retired whichever direction it moved, and '
              'the fresh hello mints the current one');
    }, tags: 'ws');

    test('a deleted account closes the session through the sweep', () async {
      // stillValid's account-deleted case (17-04b), reached through the
      // composed sweep rather than through hello: the revocation an
      // operator most naturally performs never visits the token file.
      final accounts = _Accounts();
      final fixture = _gateway(accounts, _writeTokenFile(_tempDir(),
          _twoStationFile()));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenOne).toJson(), what: 'ST101\'s hello');

      accounts.rows.remove('ST101-panel');
      await fixture.server.reloadTokensIfChanged();

      final close = await fixture.awaitClose('the deleted account\'s socket',
          budget: const Duration(seconds: 3));
      expect(close.closeCode, CloseCodes.authExpired);
    }, tags: 'ws');
  });

  group('a token file with no account resolver refuses to start (D-06)',
      () {
    test('start() throws, naming the missing resolver', () async {
      final path = _writeTokenFile(_tempDir(), _twoStationFile());
      final served = FakeStateMan();
      addTearDown(served.dispose);
      final server = RelayServer(
        resolver: const PermissiveSeriesResolver(),
        api: served,
        config: ServerConfig(auth: AuthConfig(tokenFilePath: path)),
        onError: (_, __, ___) {},
      );

      await expectLater(
          server.start(),
          throwsA(isA<Error>().having((e) => e.toString(), 'message',
              allOf(contains('accounts'), contains('UserResolver')))),
          reason: 'the message must name the parameter to wire, because the '
              'operator reading it is standing at a gateway that will not '
              'start. There is no permissive fallback — a gateway that '
              'admitted every panel because nobody wired the user source '
              'would look perfectly healthy from every screen in the plant');
    });

    test('with a resolver, the same configuration starts and binds',
        () async {
      // Anti-vacuity: the throw above proves nothing if the configuration
      // is unstartable for some other reason.
      final path = _writeTokenFile(_tempDir(), _twoStationFile());
      final served = FakeStateMan();
      final accounts = _Accounts();
      final server = RelayServer(
        resolver: const PermissiveSeriesResolver(),
        api: served,
        config: ServerConfig(auth: AuthConfig(tokenFilePath: path)),
        accounts: accounts.call,
        onError: (_, __, ___) {},
      );
      addTearDown(() async {
        await server.close();
        await served.dispose();
      });

      await server.start();
      expect(server.port, greaterThan(0),
          reason: 'started and bound: the refusal above is about the '
              'resolver, not about the rest of the configuration');
    });
  });

  group('the permissive validator is honestly labelled', () {
    test('it mints every group, and the identity says so', () async {
      final verdict =
          await const PermissiveTokenValidator().validate(_helloWith(null));

      expect(
          (verdict as TokenAccepted).identity.session.groups,
          AccessGroup.values.toSet(),
          reason: 'its semantics are "everyone may do everything", and since '
              'Phase 17 that is seven groups rather than one of two roles — '
              'the full set is that written down');
      expect(verdict.identity.user.roleName, kPermissiveRoleName);
    });

    test('exposureWarning now claims every group, before the bind', () {
      final warning = RelayServer.exposureWarning(
          ServerConfig(address: InternetAddress.anyIPv4, port: 8443));

      expect(warning, isNotNull);
      expect(warning, allOf(contains('TLS'), contains('token')),
          reason: 'the existing halves of the warning are unchanged');
      expect(warning, contains('every access group'),
          reason: 'before Phase 17 the permissive validator granted '
              '`operate`, one of two values; now it grants the full group '
              'set — administer and users included — which is a larger claim '
              'than the old "operate rights" wording made, and the warning '
              'an operator reads must make the larger claim too');
    });
  });

  group('the audit sink survives the composition (D-05, CR-01)', () {
    test('a recording sink handed to RelayServer receives the deny row a '
        'refused wire write produces', () async {
      final sink = _RecordingSink();
      final accounts = _Accounts();
      final fixture = _gateway(accounts,
          _writeTokenFile(_tempDir(), _twoStationFile()),
          audit: sink);
      await fixture.ready;
      // ST201 holds only `operate`; `key_mappings` takes `configure` (D-03).
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenTwo).toJson(), what: 'ST201\'s hello');

      final refusal = await fixture.refusal(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{}'},
          what: 'an operate-only key_mappings save');
      expect(refusal.code, ServerErrorCodes.forbidden);

      final denies = sink.rows.where((r) => !r.allowed).toList();
      expect(denies, isNotEmpty,
          reason: 'this is the seam 17-07 built against a directly-'
              'constructed PolicyStateMan; the row must arrive through the '
              'server\'s own wiring, or the ledger works in a unit test and '
              'not in the plant — Phase 10\'s CR-01 exactly');
      final row = denies.single;
      expect(row.who, 'ST201-panel',
          reason: 'attribution is the resolver-verified username (D-11)');
      expect(row.station, 'ST201');
      expect(row.origin, 'relay',
          reason: 'the column that tells a wire write from a keyboard');
    }, tags: 'ws');

    test('with no sink argument the write is still refused, through the '
        'NullAuditSink default', () async {
      // The anti-vacuity half: the trail is an account of decisions, never
      // a precondition for making them.
      final accounts = _Accounts();
      final fixture = _gateway(accounts,
          _writeTokenFile(_tempDir(), _twoStationFile()));
      await fixture.ready;
      await fixture.request(Methods.hello,
          params: _helloWith(_tokenTwo).toJson(), what: 'ST201\'s hello');

      final refusal = await fixture.refusal(DataServiceMethods.prefSetString,
          params: const {'key': 'key_mappings', 'value': '{}'},
          what: 'the same save with no sink wired');
      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'the verdict must not depend on whether anybody is '
              'recording it');
    }, tags: 'ws');
  });

  group('templates and admin are constructed per minted identity (D-11)', () {
    test('the accessFor factory runs once, at hello, with the verified '
        'identity, and its families serve the wire', () async {
      // 17-06 deliberately left templates/admin out of composeBackendRelay:
      // at compose time there is no identity to attribute to, and a made-up
      // one would be the false attribution D-11 forbids. The seam lands
      // here — the factory is invoked where the identity is minted, once
      // per verified station — and 17-11 fills it from the moved stores.
      final minted = <StationIdentity>[];
      final pair = channelPair();
      final api = FakeStateMan();
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: api,
        config: ServerConfig(),
        handles: HandleTable(),
        buffer: ConflatingSendBuffer(maxPending: 4096),
        validator: const _TwoStations(),
        accessFor: (identity) {
          minted.add(identity);
          return (
            accessTemplates: _ScopedTemplates('scoped-for-${identity.station}'),
            accessAdmin: _ScopedAdmin(),
            // Null is the explicit decision: this arm is about templates and
            // admin; config falls through to the shared source (fail closed).
            backendConfig: null,
          );
        },
        onError: (_, __, ___) {},
      );
      final client = rpc.Client(pair.client);
      unawaited(client.listen());
      addTearDown(() async {
        await client.close();
        await session.close(1000, 'identity test over');
        await api.dispose();
      });

      expect(minted, isEmpty,
          reason: 'before hello there is no identity to construct for — a '
              'factory that ran at build time would be the compose-time '
              'forgery 17-06 refused');

      await within(
          client.sendRequest(Methods.hello, _helloWith(_tokenOne).toJson()),
          'the hello');
      expect(minted, [_stationOne],
          reason: 'once, with the resolver-verified identity — the store '
              'this constructs attributes every row to it');

      final answer = await within(
          client.sendRequest(AccessMethods.templateList, const {}),
          'accessTemplates.list through the scoped family');
      expect([for (final t in answer as List) (t as Map)['name']],
          ['scoped-for-ST101'],
          reason: 'the wire must serve the identity-scoped family, through '
              'the same policy gate as everything else');
    });

    test('the factory\'s backendConfig family serves the wire too, under the '
        'same policy gate — the third slot the 17-GATE carry-forward adds',
        () async {
      // An administer-holding station, because every config member gates at
      // administer (AccessPolicy's `state_man_config` row) — the scoped
      // family must be graded exactly as a shared one would be.
      final scoped = _ScopedConfig();
      final pair = channelPair();
      final api = FakeStateMan();
      final session = RelaySession.serve(
        resolver: const PermissiveSeriesResolver(),
        channel: pair.server,
        api: api,
        config: ServerConfig(),
        handles: HandleTable(),
        buffer: ConflatingSendBuffer(maxPending: 4096),
        validator: const _AdminStation(),
        accessFor: (identity) => (
          accessTemplates: _ScopedTemplates('scoped-for-${identity.station}'),
          accessAdmin: _ScopedAdmin(),
          backendConfig: scoped,
        ),
        onError: (_, __, ___) {},
      );
      final client = rpc.Client(pair.client);
      unawaited(client.listen());
      addTearDown(() async {
        await client.close();
        await session.close(1000, 'scoped config test over');
        await api.dispose();
      });

      await within(
          client.sendRequest(Methods.hello, _helloWith(_adminToken).toJson()),
          'the admin hello');

      final answer = await within(
          client.sendRequest(AccessMethods.configRead, const {}),
          'backendConfig.read through the scoped family');
      expect((answer as Map)['configJson'], '{"opcua":[]}',
          reason: 'the wire answered the SCOPED family\'s document — the '
              'shared source has its own backendConfig here (FakeStateMan), '
              'so only the swap-in can produce this marker');
      expect(scoped.reads, 1,
          reason: 'the read reached the per-identity store exactly once; '
              'zero means the scoped source forwarded config to the shared '
              'source, which on the shipped graph is the -32011 refusal the '
              'gate measured');
    });
  });
}

// ---------------------------------------------------------------------------
// The administer-holding station the scoped-config arm needs: config members
// gate at `administer`, which neither _stationOne nor _stationTwo holds.
// ---------------------------------------------------------------------------

const _adminToken = 'ST301-4dQw8sKp2Xn6Vt1Mb9Rj5Yc7';
const _userAdmin = AuthenticatedUser(
    username: 'ST301-panel', roleName: 'Panel Admin', stationAccount: true);
const _stationAdmin = StationIdentity(
  user: _userAdmin,
  station: 'ST301',
  session: AccessSession(
      user: _userAdmin,
      groups: {AccessGroup.operate, AccessGroup.administer}),
);

final class _AdminStation implements TokenValidator {
  const _AdminStation();

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      params.token == _adminToken
          ? const TokenAccepted(_stationAdmin)
          : const TokenRejected('this gateway issued no such credential');
}

/// A recording scoped config family — the marker document tells it apart from
/// the shared source's own [FakeStateMan] config.
final class _ScopedConfig implements BackendConfigApi {
  int reads = 0;

  @override
  Future<BackendConfigDocument> read() async {
    reads++;
    return const BackendConfigDocument(
        configJson: '{"opcua":[]}', readOnlySections: ['relay']);
  }

  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);

  @override
  Future<void> write(String configJson, {String? reason}) async {}

  @override
  Future<BackendConfigDocument?> previous() async => null;

  @override
  Future<void> restorePrevious({String? reason}) async {}
}

final class _ScopedTemplates implements AccessTemplateApi {
  _ScopedTemplates(this.tag);
  final String tag;

  @override
  Future<List<AccessTemplate>> list() async =>
      [AccessTemplate(name: tag, rules: const {})];
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

final class _ScopedAdmin implements AccessAdminApi {
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

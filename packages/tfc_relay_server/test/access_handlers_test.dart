@TestOn('vm')

/// The twenty-eight access methods behind the handshake gate, and none of them
/// holding a check (17-09, ACCESS-01/-03/-05).
///
/// Twenty-eight, counted from `AccessMethods.all` rather than from any plan
/// document: 9 template + 11 admin + 3 audit + 5 config. Every arm here that
/// walks the surface is driven from that set, so a twenty-ninth name added
/// later is covered on the day it is declared rather than on the day somebody
/// remembers this file exists.
///
/// Four properties:
///
///  1. **The handshake gate covers all twenty-eight.** Each name, sent before
///     `hello`, is refused by the gate (`helloRequired`) and reaches no
///     handler. Anti-vacuity: the same twenty-eight are *answered* after a
///     `hello` from a session holding every group — a gate that refused
///     everything forever would pass the first half on its own.
///  2. **No check lives in `access_handlers.dart`.** The file's source,
///     comments stripped, contains no `policy`, no `AccessGroup`, no `.can(`
///     and no `identityOf`. The gate is the decorator the handlers are handed
///     (`PolicyStateMan`), exactly as `data_handlers.dart` holds no check —
///     a second rule in a handler is the duplication Phase 17 exists to
///     delete, even when the second rule is correct.
///  3. **The handlers are constructed with `api`, the decorator.** A
///     source-text arm on `relay_session.dart`: the one `AccessHandlers(`
///     construction names `api`, never the unwrapped source. The mistake is
///     one word long and invisible at runtime until somebody has the wrong
///     permissions, which is why it is worth a structural pin *and* the
///     behavioural arm below.
///  4. **A refused access call is refused by the server, not by the client**
///     (ACCESS-05). A real session holding only `configure` sends
///     `accessAdmin.createRole` — the frame goes out, the server answers
///     `forbidden`, and the store was never consulted. The client is not a
///     security boundary, so the refusal is measured with the client asking.
library;

import 'dart:async';
import 'dart:io';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/handle_table.dart';
import 'package:tfc_relay_server/src/relay_session.dart';
import 'package:tfc_relay_server/src/server_config.dart';
import 'package:tfc_relay_server/src/token_validator.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart' show within;

import 'support/permissive_resolver.dart';

// ---------------------------------------------------------------------------
// Identities. Stations, never people — the resolver-verified shape 17-04b
// mints, spelled as const fixtures the way concurrent_hello_test.dart spells
// its two stations.
// ---------------------------------------------------------------------------

const _configureUser = AuthenticatedUser(
    username: 'ST101-panel', roleName: 'Line Configurator',
    stationAccount: true);

/// A station holding `configure` and nothing else — enough to save key
/// mappings, and deliberately not enough for anything the four families gate.
const _configureOnly = StationIdentity(
  user: _configureUser,
  station: 'ST101',
  session:
      AccessSession(user: _configureUser, groups: {AccessGroup.configure}),
);

/// A validator that hands every session one fixed identity —
/// `alarm_ack_test.dart`'s `_AlwaysStation`, retargeted at the user model.
final class _MintedStation implements TokenValidator {
  const _MintedStation(this.identity);
  final StationIdentity identity;

  @override
  Future<TokenVerdict> validate(HelloParams params) async =>
      TokenAccepted(identity);
}

// ---------------------------------------------------------------------------
// A source whose four families really answer — and write down what they were
// asked. `FakeStateMan` refuses all four by name (17-03b's repair pattern),
// which is right for the kit and useless for arm 6: "the family reaches its
// backend implementation" needs a backend implementation to reach.
// ---------------------------------------------------------------------------

final class _RecordingTemplates implements AccessTemplateApi {
  _RecordingTemplates(this.tag);
  final String tag;
  final writes = <String>[];

  @override
  Future<List<AccessTemplate>> list() async =>
      [AccessTemplate(name: tag, rules: const {})];
  @override
  Future<Map<String, String>> bindings() async => {'CN01.MOT01.speed': tag};
  @override
  Future<List<String>> keysBoundTo(String templateName) async =>
      ['CN01.MOT01.speed'];
  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      writes.add('create:${value.name}');
  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      writes.add('update:${value.name}');
  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      writes.add('rename:$from:$to');
  @override
  Future<void> delete(String name, {String? reason}) async =>
      writes.add('delete:$name');
  @override
  Future<void> bind(String keyName, String templateName,
          {String? reason}) async =>
      writes.add('bind:$keyName:$templateName');
  @override
  Future<void> unbind(String keyName, {String? reason}) async =>
      writes.add('unbind:$keyName');
}

final class _RecordingAdmin implements AccessAdminApi {
  _RecordingAdmin(this.tag);
  final String tag;
  final writes = <String>[];

  @override
  Future<List<AccessRole>> roles() async =>
      [AccessRole.fromDb(name: tag, groupsJson: '[]', seeded: false)];
  @override
  Future<List<UserSummary>> listUsers() async => [
        UserSummary(
            username: tag,
            roleName: 'Panel Operator',
            stationAccount: true,
            createdAt: DateTime.utc(2026, 3, 4, 5, 6),
            lastLoginAt: DateTime.utc(2026, 3, 5, 6, 7)),
      ];
  @override
  Future<void> createRole(AccessRole role, {String? reason}) async =>
      writes.add('createRole:${role.name}');
  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async =>
      writes.add('updateRole:${role.name}');
  @override
  Future<void> deleteRole(String name, {String? reason}) async =>
      writes.add('deleteRole:$name');
  @override
  Future<void> renameRole(String from, String to, {String? reason}) async =>
      writes.add('renameRole:$from:$to');
  @override
  Future<void> createUser(NewUserParams params) async =>
      writes.add('createUser:${params.subject}');
  @override
  Future<void> deleteUser(String subject, {String? reason}) async =>
      writes.add('deleteUser:$subject');
  @override
  Future<void> setUserRole(String subject, String newRole,
          {String? reason}) async =>
      writes.add('setUserRole:$subject:$newRole');
  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) async =>
      writes.add('setUserStationAccount:$subject:$value');
  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async =>
      writes.add('setUserPassword:${params.subject}');
}

final class _RecordingAudit implements AuditApi {
  _RecordingAudit(this.tag);
  final String tag;

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async => [
        AuditRecord(
          at: DateTime.utc(2026, 9, 8),
          who: tag,
          station: 'ST101',
          roleName: 'Panel Operator',
          surface: 'pref',
          itemKey: 'theme_mode',
          groupRequired: 'operate',
          allowed: true,
          origin: 'relay',
          actionId: 'probe',
        ),
      ];
  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async =>
      {for (final id in actionIds) id: 1};
  @override
  Future<List<String>> distinctWho() async => [tag];
}

final class _RecordingConfig implements BackendConfigApi {
  _RecordingConfig(this.tag);
  final String tag;
  final writes = <String>[];

  @override
  Future<BackendConfigDocument> read() async => BackendConfigDocument(
      configJson: tag, readOnlySections: const ['relay'], hasPrevious: true);
  @override
  Future<ConfigValidation> validate(String configJson) async =>
      const ConfigValidation(ok: true);
  @override
  Future<void> write(String configJson, {String? reason}) async =>
      writes.add('write');
  @override
  Future<BackendConfigDocument?> previous() async =>
      BackendConfigDocument(configJson: tag);
  @override
  Future<void> restorePrevious({String? reason}) async =>
      writes.add('restorePrevious');
}

/// [FakeStateMan] whose four family getters answer instead of refusing.
final class _ServingSource extends FakeStateMan {
  _ServingSource(this.tag);
  final String tag;

  late final templates = _RecordingTemplates(tag);
  late final admin = _RecordingAdmin(tag);
  late final auditTrail = _RecordingAudit(tag);
  late final backendCfg = _RecordingConfig(tag);

  @override
  AccessTemplateApi get accessTemplates => templates;
  @override
  AccessAdminApi get accessAdmin => admin;
  @override
  AuditApi get audit => auditTrail;
  @override
  BackendConfigApi get backendConfig => backendCfg;
}

// ---------------------------------------------------------------------------
// The wire params each method needs to be *answered*, not merely reached.
//
// A table beside `AccessMethods.all` rather than instead of it: the iteration
// below is from the declared set, and the closure arm pins that this table
// names exactly that set — so a new wire name without a row here fails naming
// the method, and a stale row names the name that left.
// ---------------------------------------------------------------------------

const Map<String, Map<String, Object?>> _validParams = {
  AccessMethods.templateList: {},
  AccessMethods.templateBindings: {},
  AccessMethods.templateKeysBoundTo: {'templateName': 'Ops'},
  // 17-14 F-3: the single-DTO members carry the DTO under a `value`/`role`/
  // `query` envelope key — the shape the channel kit's served side and 17-08's
  // client both send, and the shape this handler was reconciled to.
  AccessMethods.templateCreate: {
    'value': {'name': 'T-wire', 'rules': ''}
  },
  AccessMethods.templateUpdate: {
    'value': {'name': 'T-wire', 'rules': ''}
  },
  AccessMethods.templateRename: {'from': 'T-wire', 'to': 'T-wire-2'},
  AccessMethods.templateDelete: {'name': 'T-wire'},
  AccessMethods.templateBind: {
    'keyName': 'CN01.MOT01.speed',
    'templateName': 'T-wire'
  },
  AccessMethods.templateUnbind: {'keyName': 'CN01.MOT01.speed'},
  AccessMethods.adminRoles: {},
  AccessMethods.adminListUsers: {},
  AccessMethods.adminCreateRole: {
    'role': {'name': 'Wire Role', 'groups': '[]'}
  },
  AccessMethods.adminUpdateRole: {
    'role': {'name': 'Wire Role', 'groups': '[]'}
  },
  AccessMethods.adminDeleteRole: {'name': 'Wire Role'},
  AccessMethods.adminRenameRole: {'from': 'Wire Role', 'to': 'Wire Role 2'},
  AccessMethods.adminCreateUser: {
    'subject': 'ST999-panel',
    'password': 'wire-probe-credential-000000',
    'grantedRole': 'Wire Role',
  },
  AccessMethods.adminDeleteUser: {'subject': 'ST999-panel'},
  AccessMethods.adminSetUserRole: {
    'subject': 'ST999-panel',
    'newRole': 'Wire Role'
  },
  AccessMethods.adminSetUserStationAccount: {
    'subject': 'ST999-panel',
    'value': true
  },
  AccessMethods.adminSetUserPassword: {
    'subject': 'ST999-panel',
    'password': 'wire-probe-credential-000001',
  },
  AccessMethods.auditEntries: {
    'query': {'keyPrefix': ''}
  },
  AccessMethods.auditMemberCountsByAction: {
    'actionIds': ['probe']
  },
  AccessMethods.auditDistinctWho: {},
  AccessMethods.configRead: {},
  AccessMethods.configValidate: {'configJson': '{}'},
  AccessMethods.configWrite: {'configJson': '{}'},
  AccessMethods.configPrevious: {},
  AccessMethods.configRestorePrevious: {},
};

// ---------------------------------------------------------------------------
// One session over an in-memory channel — `alarm_ack_test.dart`'s `_Link`,
// with the identity and the source as the levers.
// ---------------------------------------------------------------------------

final class _Link {
  _Link(this.session, this.client, this.api);
  final RelaySession session;
  final rpc.Client client;
  final FakeStateMan api;

  Future<void> dispose() async {
    await client.close();
    await session.close(1000, 'access handlers test over');
    await api.dispose();
  }

  Future<Object?> hello() => within(
      client.sendRequest(
          Methods.hello,
          HelloParams(
            protocol: protocolVersion,
            supported: const [protocolVersion],
            client: const PeerInfo('panel-under-test', '0.1.0'),
          ).toJson()),
      'the hello result');
}

_Link _link({TokenValidator? validator, FakeStateMan? api}) {
  final pair = channelPair();
  final source = api ?? _ServingSource('probe');
  final session = RelaySession.serve(
    resolver: const PermissiveSeriesResolver(),
    channel: pair.server,
    api: source,
    config: ServerConfig(),
    handles: HandleTable(),
    buffer: ConflatingSendBuffer(maxPending: 4096),
    validator: validator ?? const PermissiveTokenValidator(),
    serverSupported: const [protocolVersion],
    // Several arms provoke refusals on purpose.
    onError: (_, __, ___) {},
  );
  final client = rpc.Client(pair.client);
  unawaited(client.listen());
  final link = _Link(session, client, source);
  addTearDown(link.dispose);
  return link;
}

Future<rpc.RpcException> _refused(Future<Object?> call, String what) async {
  try {
    await call;
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

/// [source]'s non-comment text — the same stripping discipline every grep pin
/// in this phase uses (`grep -v '^\s*//'`), so a doc comment that *mentions*
/// the forbidden token does not trip the arm.
String _stripped(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  test('the params table names exactly the declared surface', () {
    // Driven-from-the-set means nothing if the table underneath the iteration
    // has quietly diverged: a method in `all` with no row would skip its
    // success half, and a row for a name that left would test air.
    expect(_validParams.keys.toSet(), AccessMethods.all,
        reason: 'one equality, both directions: a name in AccessMethods.all '
            'with no params row cannot have its post-hello half exercised, '
            'and a row naming nothing on the wire is a claim about surface '
            'that does not exist');
    expect(AccessMethods.all, hasLength(28),
        reason: 'twenty-eight is the count the audit cut settled on '
            '(accessTemplates.template removed, no caller anywhere). A '
            'twenty-ninth is an access-control decision, not a convenience — '
            'grow this literal deliberately');
  });

  group('the handshake gate covers every access method', () {
    for (final method in AccessMethods.all) {
      test('$method before hello is refused by the gate', () async {
        final source = _ServingSource('pre-hello');
        final link = _link(api: source);

        final refusal = await _refused(
            link.client.sendRequest(method, _validParams[method] ?? const {}),
            'a pre-hello $method');

        expect(refusal.code, ServerErrorCodes.helloRequired,
            reason: 'a frame arriving before hello must be refused by the '
                'gate — helloRequired, the code every method registered '
                'through _on answers. Anything else (a -32601, a forbidden, '
                'an answer) means $method is either unregistered or '
                'registered around the one seam');
        expect(
            [
              ...source.templates.writes,
              ...source.admin.writes,
              ...source.backendCfg.writes,
            ],
            isEmpty,
            reason: 'the gate refused, so no handler — and no store — may '
                'have been reached');
      });
    }

    for (final method in AccessMethods.all) {
      test('$method after a hello holding every group is answered', () async {
        // The anti-vacuity half (D-12): a gate that refuses everything
        // forever satisfies every pre-hello arm above. The permissive
        // validator mints the full group set, so the only thing between the
        // frame and the fake source is plumbing that must work.
        final link = _link();
        await link.hello();

        final answer = await within(
            link.client.sendRequest(method, _validParams[method] ?? const {}),
            'a post-hello $method');

        // `null` is a legitimate answer for the void writes; the property is
        // that the call was *answered* rather than refused, which
        // sendRequest already guarantees by not throwing.
        expect(answer, anything);
      });
    }
  });

  group('no check lives in access_handlers.dart', () {
    final file = File('lib/src/access_handlers.dart');

    test('the file exists and is substantial', () {
      // Anti-vacuity for the grep below: zero hits over a missing file is a
      // zero somebody could trust.
      expect(file.existsSync(), isTrue,
          reason: 'lib/src/access_handlers.dart is not there — the twenty-'
              'eight handlers have no home and every grep below is noise');
      expect(file.readAsLinesSync().length, greaterThan(150),
          reason: 'twenty-eight decode-and-delegate methods do not fit in '
              'fewer lines; a shorter file is a stub wearing the name');
    });

    test('comments stripped, the forbidden tokens appear zero times', () {
      final text = _stripped(file.readAsStringSync());
      for (final needle in ['policy', 'AccessGroup', '.can(', 'identityOf']) {
        expect(text.contains(needle), isFalse,
            reason: '"$needle" appears in access_handlers.dart outside a '
                'comment. The check belongs to the decorator the handlers '
                'are handed (PolicyStateMan) — a check here is a second rule, '
                'and a second correct rule still fails the phase '
                '(17-CONTEXT, the constitution)');
      }
    });
  });

  group('the handlers are constructed with the decorator', () {
    test('relay_session.dart constructs AccessHandlers(source: api)', () {
      final text =
          _stripped(File('lib/src/relay_session.dart').readAsStringSync());
      final constructions = 'AccessHandlers('.allMatches(text).toList();
      expect(constructions, hasLength(1),
          reason: 'exactly one AccessHandlers construction: zero means the '
              'families are not wired, two means a second table someone can '
              'hand the wrong source');
      final start = constructions.single.end;
      final span = text.substring(start, text.indexOf(')', start));
      expect(span, contains('source: api'),
          reason: 'the construction must name `api` — the session\'s '
              'PolicyStateMan — and never `_source`, the unwrapped plant. '
              'The difference is one word, invisible at runtime until '
              'somebody has the wrong permissions. Found: '
              '"AccessHandlers($span)"');
      expect(span, isNot(contains('_source')),
          reason: 'the unwrapped source in this argument list is the bypass '
              'the structural arm exists to catch');
    });
  });

  group('a refused access call is refused by the server (ACCESS-05)', () {
    test('a configure-only station\'s createRole is refused forbidden, and '
        'the store is untouched', () async {
      final source = _ServingSource('refusal-probe');
      final link =
          _link(validator: const _MintedStation(_configureOnly), api: source);
      await link.hello();

      // The frame IS sent — the client is not a security boundary, so the
      // refusal must be measured with the client asking, not declining to
      // ask.
      final refusal = await _refused(
          link.client.sendRequest(AccessMethods.adminCreateRole,
              _validParams[AccessMethods.adminCreateRole]),
          'a configure-only createRole');

      expect(refusal.code, ServerErrorCodes.forbidden,
          reason: 'the server\'s verdict, on the wire: the role write takes '
              '`users` (AccessPolicy.groupForAdmin), and this station holds '
              'only `configure`');
      expect(source.admin.writes, isEmpty,
          reason: 'the store was consulted despite the refusal — the gate '
              'threw after the effect, which is a refusal in name only');
    });

    test('the same frame from a users-holding session reaches the store',
        () async {
      // The live control (D-12): without it the arm above is satisfied by a
      // gate that refuses everybody, which is exactly what sabotage (h) in
      // 17-06 demonstrated.
      final source = _ServingSource('allow-probe');
      final link = _link(api: source);
      await link.hello();

      await within(
          link.client.sendRequest(AccessMethods.adminCreateRole,
              _validParams[AccessMethods.adminCreateRole]),
          'a full-group createRole');

      expect(source.admin.writes, ['createRole:Wire Role'],
          reason: 'the permitted neighbour must actually land — a filter '
              'that removed everything passes every refusal arm and breaks '
              'the plant');
    });
  });

  group('every family reaches its backend implementation', () {
    test('template list answers came from the source, not a default',
        () async {
      final link = _link(api: _ServingSource('ÞT-ONE'));
      await link.hello();

      final answer = await within(
          link.client.sendRequest(AccessMethods.templateList, const {}),
          'accessTemplates.list');

      expect(
          [for (final t in answer as List) (t as Map)['name']], ['ÞT-ONE'],
          reason: 'the distinctive seed must round-trip; an empty list here '
              'is a handler answering a default while claiming a backend');
    });

    test('admin listUsers answers came from the source', () async {
      final link = _link(api: _ServingSource('gw-verify'));
      await link.hello();

      final answer = await within(
          link.client.sendRequest(AccessMethods.adminListUsers, const {}),
          'accessAdmin.listUsers');

      expect([for (final u in answer as List) (u as Map)['username']],
          ['gw-verify']);
    });

    test('audit distinctWho answers came from the source', () async {
      final link = _link(api: _ServingSource('jón-verify'));
      await link.hello();

      final answer = await within(
          link.client.sendRequest(AccessMethods.auditDistinctWho, const {}),
          'audit.distinctWho');

      expect(answer, ['jón-verify']);
    });

    test('config read answers came from the source', () async {
      const probe = '{"probe":"seventeen-oh-nine"}';
      final link = _link(api: _ServingSource(probe));
      await link.hello();

      final answer = await within(
          link.client.sendRequest(AccessMethods.configRead, const {}),
          'backendConfig.read');

      expect((answer as Map)['configJson'], probe);
      expect(answer['readOnlySections'], ['relay'],
          reason: 'D-10: the section that configures the socket the edit '
              'arrives on travels marked read-only, so the screen can grey '
              'it instead of letting an operator type into a field that '
              'cannot be saved');
    });

    test('a template write carries its arguments through', () async {
      final source = _ServingSource('write-probe');
      final link = _link(api: source);
      await link.hello();

      await within(
          link.client.sendRequest(AccessMethods.templateBind,
              _validParams[AccessMethods.templateBind]),
          'accessTemplates.bind');

      expect(source.templates.writes, ['bind:CN01.MOT01.speed:T-wire'],
          reason: 'the decode is the handler\'s whole job; a bind that '
              'reached the store with the wrong arguments re-points who may '
              'write a key');
    });
  });
}

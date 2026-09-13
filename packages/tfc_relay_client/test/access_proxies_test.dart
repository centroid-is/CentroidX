@TestOn('vm')

/// The four access proxies: templates, roles-and-users, the audit trail and
/// the backend's config, each one request out and one answer back — and the
/// three properties that make them more than boilerplate.
///
/// **The far end is the enforcement.** A client-side method call cannot write
/// what the gateway's policy refuses; what this file pins is everything the
/// *client* could still get wrong on the way there:
///
///  1. the payload carries no identity (ACCESS-06's client half — arm 2),
///  2. a `forbidden` arrives as the same `AccessDenied` a direct-mode refusal
///     throws, message intact (D-09 — arms 3 and 4),
///  3. a refusal — or a transport error — is never retried (arm 5),
///  4. a domain error crosses as a structured payload, fields intact (arm 6).
///
/// The scripted-call fixture is this package's own: the recording
/// `RemoteCall` closure `type_mismatch_test.dart:31-32` drives the
/// preferences proxy with, grown a request log — the same shape
/// `deadline_test.dart:55-111`'s `_ScriptedPeer` records at the frame level.
/// Arm 8's in-memory gateway is `deadline_test.dart`'s scripted peer wired
/// under the real `dial:` seam, so the whole `RemoteStateMan` request path
/// (barrier, deadline, peer-at-call-time) is what the contract judges.
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_client/src/client_config.dart';
import 'package:tfc_relay_client/src/client_sub_apis.dart';
import 'package:tfc_relay_client/src/remote_state_man.dart';
import 'package:tfc_relay_client/src/ws_transport.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';
import 'package:tfc_stateman_contract/testing/fake_access_services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// -----------------------------------------------------------------------------
// The two wire error codes this file drives, spelled locally
// -----------------------------------------------------------------------------

/// The gateway's `ServerErrorCodes.forbidden`. Declared here rather than
/// imported, for `type_mismatch_test.dart:23-28`'s reason: `tfc_relay_server`
/// is a dev dependency and the number *is* the contract — two literals in two
/// files that a case fails the moment they disagree.
const int _forbidden = -32005;

/// The gateway's `ServerErrorCodes.handlerFailed` — the code a *domain*
/// refusal (a bound template, the last users-holder, a bad config) travels
/// under. Deliberately not [_forbidden]: "you may not" and "you cannot yet"
/// must stay distinguishable on the wire.
const int _handlerFailed = -32011;

/// The wording the gateway puts on a refusal — a `forbidden` on this wire
/// means the call definitively had no effect (STATE.md Phase 1 handoff), and
/// the operator must read the same sentence whichever transport refused it.
const String _refusalWording =
    'definitively had no effect and must not be retried';

// -----------------------------------------------------------------------------
// The scripted recording call
// -----------------------------------------------------------------------------

/// A [RemoteCall] that records every request and answers from a script — the
/// `type_mismatch_test.dart:31-32` closure with a request log attached.
final class _Recorder {
  _Recorder(this._answer);

  /// Answers one request, or throws what the script says the gateway threw.
  final Object? Function(String method, Map<String, Object?> params) _answer;

  /// Every request this recorder saw, in order.
  final List<({String method, Map<String, Object?> params})> requests =
      <({String method, Map<String, Object?> params})>[];

  Future<Object?> call(String method, Map<String, Object?> params) async {
    requests.add((method: method, params: params));
    return _answer(method, params);
  }
}

/// The four proxies over one call — what a `RemoteStateMan` holds, minus the
/// socket.
final class _Apis {
  _Apis(RemoteCall call)
      : templates = ClientAccessTemplateApi(call),
        admin = ClientAccessAdminApi(call),
        audit = ClientAuditApi(call),
        config = ClientBackendConfigApi(call);

  final ClientAccessTemplateApi templates;
  final ClientAccessAdminApi admin;
  final ClientAuditApi audit;
  final ClientBackendConfigApi config;
}

// -----------------------------------------------------------------------------
// Fixtures the table exchanges
// -----------------------------------------------------------------------------

final AccessTemplate _template =
    AccessTemplate(name: 'conveyor-1', rules: const {
  kWholeKeyMember: AccessGroup.setpoints,
});

final AccessRole _role =
    AccessRole(name: 'Line Lead', groups: const {AccessGroup.operate});

final UserSummary _user = UserSummary(
  username: 'ST101-panel',
  roleName: 'Panel Operator',
  stationAccount: true,
  // Both timestamps set, so the round trip proves 17-08's F-1 crosses: the
  // roster row used to be an `AuthenticatedUser`, which had nowhere to put a
  // date, and every account rendered as 1970 on a gateway station.
  createdAt: DateTime.utc(2026, 4, 1, 7, 30),
  lastLoginAt: DateTime.utc(2026, 9, 8, 6, 15),
);

final AuditRecord _auditRow = AuditRecord(
  at: DateTime.fromMillisecondsSinceEpoch(1757300000000, isUtc: true),
  who: 'ST101-panel',
  station: 'ST101',
  roleName: 'Panel Operator',
  surface: 'template',
  itemKey: 'conveyor-1',
  groupRequired: 'users',
  allowed: true,
  origin: 'relay',
  actionId: 'a-1',
);

const _configDoc = BackendConfigDocument(
  configJson: '{"relay":{"port":8443},"sources":{}}',
  readOnlySections: ['relay'],
  hasPrevious: true,
);

// -----------------------------------------------------------------------------
// The member table: every member of all four families, one row each
// -----------------------------------------------------------------------------

/// One family member: its wire name, how to drive it, what the gateway
/// answers, and (for reads) what the decoded answer must look like.
final class _Member {
  const _Member(this.wire, this.drive, this.answer, {this.check});

  /// The wire name — `AccessMethods`' constant, compared as a set against
  /// [AccessMethods.all] so a member added later without a row is visible.
  final String wire;

  /// Invokes the member through its proxy and returns whatever it decoded.
  final Future<Object?> Function(_Apis apis) drive;

  /// What the scripted gateway answers.
  final Object? Function() answer;

  /// Asserts the decoded answer, where the member answers with data.
  final void Function(Object? decoded)? check;
}

final List<_Member> _members = <_Member>[
  // ------------------------------------------------------------- templates
  _Member(
    AccessMethods.templateList,
    (a) => a.templates.list(),
    () => [accessTemplateToJson(_template)],
    check: (decoded) => expect(
        (decoded! as List<AccessTemplate>).single.name, _template.name),
  ),
  _Member(
    AccessMethods.templateBindings,
    (a) => a.templates.bindings(),
    () => {'ST101.CN01.MOT01': 'conveyor-1'},
    check: (decoded) => expect(decoded, {'ST101.CN01.MOT01': 'conveyor-1'}),
  ),
  _Member(
    AccessMethods.templateKeysBoundTo,
    (a) => a.templates.keysBoundTo('conveyor-1'),
    () => ['ST101.CN01.MOT01'],
    check: (decoded) => expect(decoded, ['ST101.CN01.MOT01']),
  ),
  _Member(AccessMethods.templateCreate,
      (a) => a.templates.create(_template, reason: 'why'), () => null),
  _Member(AccessMethods.templateUpdate, (a) => a.templates.update(_template),
      () => null),
  _Member(AccessMethods.templateRename,
      (a) => a.templates.rename('conveyor-1', 'conveyor-2'), () => null),
  _Member(AccessMethods.templateDelete, (a) => a.templates.delete('conveyor-1'),
      () => null),
  _Member(AccessMethods.templateBind,
      (a) => a.templates.bind('ST101.CN01.MOT01', 'conveyor-1'), () => null),
  _Member(AccessMethods.templateUnbind,
      (a) => a.templates.unbind('ST101.CN01.MOT01'), () => null),
  // -------------------------------------------------------- roles and users
  _Member(
    AccessMethods.adminRoles,
    (a) => a.admin.roles(),
    () => [accessRoleToJson(_role)],
    check: (decoded) =>
        expect((decoded! as List<AccessRole>).single.name, _role.name),
  ),
  _Member(
    AccessMethods.adminListUsers,
    (a) => a.admin.listUsers(),
    () => [userSummaryToJson(_user)],
    check: (decoded) {
      final row = (decoded! as List<UserSummary>).single;
      expect(row.username, _user.username);
      expect(row.createdAt, _user.createdAt);
      expect(row.lastLoginAt, _user.lastLoginAt);
    },
  ),
  _Member(AccessMethods.adminCreateRole, (a) => a.admin.createRole(_role),
      () => null),
  _Member(AccessMethods.adminUpdateRole, (a) => a.admin.updateRole(_role),
      () => null),
  _Member(AccessMethods.adminDeleteRole, (a) => a.admin.deleteRole('Line Lead'),
      () => null),
  _Member(AccessMethods.adminRenameRole,
      (a) => a.admin.renameRole('Line Lead', 'Shift Lead'), () => null),
  _Member(
      AccessMethods.adminCreateUser,
      (a) => a.admin.createUser(const NewUserParams(
          subject: 'nyr-madur', password: 'hunang-123', grantedRole: 'Operator')),
      () => null),
  _Member(AccessMethods.adminDeleteUser, (a) => a.admin.deleteUser('nyr-madur'),
      () => null),
  _Member(AccessMethods.adminSetUserRole,
      (a) => a.admin.setUserRole('nyr-madur', 'Supervisor'), () => null),
  _Member(AccessMethods.adminSetUserStationAccount,
      (a) => a.admin.setUserStationAccount('nyr-madur', true), () => null),
  // Both nulls are exercised elsewhere; the table's job is one request and one
  // answer per member, so a non-null set is enough here.
  _Member(AccessMethods.adminSetRolePages,
      (a) => a.admin.setRolePages('Supervisor', {'/fillet'}), () => null),
  _Member(AccessMethods.adminSetUserPages,
      (a) => a.admin.setUserPages('nyr-madur', {'/fillet'}), () => null),
  _Member(
      AccessMethods.adminSetUserPassword,
      (a) => a.admin.setUserPassword(const SetUserPasswordParams(
          subject: 'nyr-madur', password: 'nytt-lykilord')),
      () => null),
  // ------------------------------------------------------------------ audit
  _Member(
    AccessMethods.auditEntries,
    // A windowless query with no `who` filter: the one legitimate `who` on
    // this family is a *filter* inside AuditQueryParams, and driving the
    // table without it is what lets arm 2 forbid the key outright.
    (a) => a.audit.entries(const AuditQueryParams()),
    () => [auditRecordToJson(_auditRow)],
    check: (decoded) =>
        expect((decoded! as List<AuditRecord>).single.who, _auditRow.who),
  ),
  _Member(
    AccessMethods.auditMemberCountsByAction,
    (a) => a.audit.memberCountsByAction(const ['a-1']),
    () => {'a-1': 2},
    check: (decoded) => expect(decoded, {'a-1': 2}),
  ),
  _Member(
    AccessMethods.auditDistinctWho,
    (a) => a.audit.distinctWho(),
    () => ['ST101-panel'],
    check: (decoded) => expect(decoded, ['ST101-panel']),
  ),
  // --------------------------------------------------------- backend config
  _Member(
    AccessMethods.configRead,
    (a) => a.config.read(),
    () => _configDoc.toJson(),
    check: (decoded) => expect(
        (decoded! as BackendConfigDocument).readOnlySections, contains('relay')),
  ),
  _Member(
    AccessMethods.configValidate,
    (a) => a.config.validate('{"relay":{"port":8443}}'),
    () => const ConfigValidation(ok: true).toJson(),
    check: (decoded) => expect((decoded! as ConfigValidation).ok, isTrue),
  ),
  _Member(AccessMethods.configWrite,
      (a) => a.config.write('{"relay":{"port":8443}}'), () => null),
  _Member(
    AccessMethods.configPrevious,
    (a) => a.config.previous(),
    () => _configDoc.toJson(),
    check: (decoded) => expect(decoded, isA<BackendConfigDocument>()),
  ),
  _Member(AccessMethods.configRestorePrevious,
      (a) => a.config.restorePrevious(), () => null),
];

// -----------------------------------------------------------------------------
// Arm 2's forbidden identity keys
// -----------------------------------------------------------------------------

/// No encoded payload may carry any of these, at any nesting depth.
///
/// The first nine are the plan's; `origin`, `actor` and `session` are 17-03's
/// own additions (its deviation 3): `origin` is the audit column that says a
/// row came from the relay rather than a keyboard, and a client that could set
/// it could dress a wire write up as an operator's.
const Set<String> _identityKeys = {
  'who',
  'username',
  'userId',
  'user',
  'identity',
  'station',
  'stationId',
  'roleName',
  'operator',
  'origin',
  'actor',
  'session',
};

/// Every key in [value], at every depth.
Iterable<String> _keysOf(Object? value) sync* {
  if (value is Map) {
    for (final entry in value.entries) {
      yield '${entry.key}';
      yield* _keysOf(entry.value);
    }
  } else if (value is List) {
    for (final element in value) {
      yield* _keysOf(element);
    }
  }
}

// -----------------------------------------------------------------------------
// Arm 8's in-memory leg
// -----------------------------------------------------------------------------

/// The socket behind [ConnectSucceeded] that the in-memory leg never touches.
///
/// `ConnectSucceeded` reads it only for `closeCode` / `closeReason`; the
/// supervisor destructures `:final channel` and never reaches past it. Anything
/// else throwing loudly is the assertion that stays true.
final class _UnusedSocket implements WebSocketChannel {
  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
      'the in-memory access leg never touches the socket behind '
      'ConnectSucceeded: ${invocation.memberName}');
}

/// Narrows a `Parameters`-shaped map to the string-keyed shape the codecs take.
Map<String, Object?> _obj(Map<Object?, Object?> raw) =>
    {for (final entry in raw.entries) '${entry.key}': entry.value};

/// A scripted gateway on the far end of an in-memory channel: it answers
/// `hello` and the twenty-eight access methods, backed by [FakeAccessServices],
/// and maps the two refusal shapes exactly as the real gateway must —
/// [AccessDenied] to [_forbidden] with the item key and required group in
/// `data`, everything else to [_handlerFailed] with the domain payload intact.
///
/// The shape is `deadline_test.dart:55-111`'s scripted peer, answering from a
/// live fake instead of a script — and, like `served_state_man.dart:477-489`,
/// it mints no refusal of its own: every verdict is the fake's.
final class _ServedAccessGateway {
  _ServedAccessGateway(this.fake)
      : _controller = StreamChannelController<String>() {
    _peer = rpc.Peer(_controller.foreign);
    _register();
    unawaited(_peer.listen().catchError((Object _) {}));
  }

  final FakeAccessServices fake;
  final StreamChannelController<String> _controller;
  late final rpc.Peer _peer;

  /// The client's half of the channel, worn as a [ConnectAttempt] so the real
  /// `dial:` seam — and everything downstream of it — is what carries the leg.
  ConnectAttempt attempt() =>
      ConnectSucceeded(_UnusedSocket(), _controller.local);

  Future<void> dispose() => _peer.close();

  /// Registers one access method: the work, then the two refusal mappings.
  void _on(String method, Future<Object?> Function(rpc.Parameters) work) {
    _peer.registerMethod(method, (rpc.Parameters params) async {
      try {
        return await work(params);
      } on AccessDenied catch (denial) {
        throw rpc.RpcException(
          _forbidden,
          '$denial The call $_refusalWording.',
          data: {'itemKey': denial.itemKey, 'group': denial.required.name},
        );
      } on rpc.RpcException {
        rethrow;
      } catch (error) {
        throw rpc.RpcException(_handlerFailed, '$method failed: $error');
      }
    });
  }

  void _register() {
    _peer.registerMethod(
        Methods.hello,
        (rpc.Parameters params) => HelloResult(
              protocol: protocolVersion,
              server: const PeerInfo('scripted-access-gateway', '0.0.1'),
              sessionId: 'S1',
              epoch: 'E1',
              serverTime: DateTime.now().millisecondsSinceEpoch,
            ).toJson());

    String? reasonOf(rpc.Parameters params) =>
        params['reason'].valueOr(null) as String?;

    // templates
    _on(AccessMethods.templateList,
        (p) async => [for (final t in await fake.list()) accessTemplateToJson(t)]);
    _on(AccessMethods.templateBindings, (p) async => await fake.bindings());
    _on(AccessMethods.templateKeysBoundTo,
        (p) async => await fake.keysBoundTo(p['templateName'].asString));
    _on(AccessMethods.templateCreate, (p) async {
      await fake.create(accessTemplateFromJson(_obj(p['value'].asMap)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.templateUpdate, (p) async {
      await fake.update(accessTemplateFromJson(_obj(p['value'].asMap)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.templateRename, (p) async {
      await fake.rename(p['from'].asString, p['to'].asString,
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.templateDelete, (p) async {
      await fake.delete(p['name'].asString, reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.templateBind, (p) async {
      await fake.bind(p['keyName'].asString, p['templateName'].asString,
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.templateUnbind, (p) async {
      await fake.unbind(p['keyName'].asString, reason: reasonOf(p));
      return null;
    });

    // roles and users
    _on(AccessMethods.adminRoles,
        (p) async => [for (final r in await fake.roles()) accessRoleToJson(r)]);
    _on(
        AccessMethods.adminListUsers,
        (p) async =>
            [for (final u in await fake.listUsers()) userSummaryToJson(u)]);
    _on(AccessMethods.adminCreateRole, (p) async {
      await fake.createRole(accessRoleFromJson(_obj(p['role'].asMap)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminUpdateRole, (p) async {
      await fake.updateRole(accessRoleFromJson(_obj(p['role'].asMap)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminDeleteRole, (p) async {
      await fake.deleteRole(p['name'].asString, reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminRenameRole, (p) async {
      await fake.renameRole(p['from'].asString, p['to'].asString,
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminCreateUser, (p) async {
      await fake.createUser(NewUserParams.fromJson(_obj(p.asMap)));
      return null;
    });
    _on(AccessMethods.adminDeleteUser, (p) async {
      await fake.deleteUser(p['subject'].asString, reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminSetUserRole, (p) async {
      await fake.setUserRole(p['subject'].asString, p['newRole'].asString,
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminSetUserStationAccount, (p) async {
      await fake.setUserStationAccount(
          p['subject'].asString, p['value'].asBool,
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminSetRolePages, (p) async {
      await fake.setRolePages(
          p['subject'].asString, pagesFromJson(p['pages'].valueOr(null)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminSetUserPages, (p) async {
      await fake.setUserPages(
          p['subject'].asString, pagesFromJson(p['pages'].valueOr(null)),
          reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.adminSetUserPassword, (p) async {
      await fake.setUserPassword(SetUserPasswordParams.fromJson(_obj(p.asMap)));
      return null;
    });

    // audit
    _on(
        AccessMethods.auditEntries,
        (p) async => [
              for (final row in await fake
                  .entries(AuditQueryParams.fromJson(_obj(p['query'].asMap))))
                auditRecordToJson(row)
            ]);
    _on(AccessMethods.auditMemberCountsByAction, (p) async {
      final ids = [for (final id in p['actionIds'].asList) '$id'];
      return await fake.memberCountsByAction(ids);
    });
    _on(AccessMethods.auditDistinctWho, (p) async => await fake.distinctWho());

    // backend config
    _on(AccessMethods.configRead, (p) async => (await fake.read()).toJson());
    _on(AccessMethods.configValidate,
        (p) async => (await fake.validate(p['configJson'].asString)).toJson());
    _on(AccessMethods.configWrite, (p) async {
      await fake.write(p['configJson'].asString, reason: reasonOf(p));
      return null;
    });
    _on(AccessMethods.configPrevious,
        (p) async => (await fake.previous())?.toJson());
    _on(AccessMethods.configRestorePrevious, (p) async {
      await fake.restorePrevious(reason: reasonOf(p));
      return null;
    });
  }
}

/// The client's timing knobs for the in-memory leg. The freshness deadline is
/// generous because the scripted gateway sends no ticks — every inbound frame
/// here is an RPC answer — and a leg reaped for a silence that is the
/// fixture's own shape would fail cases about something else entirely.
ClientConfig _legConfig() => ClientConfig(
      controlDeadline: const Duration(seconds: 2),
      writeDeadline: const Duration(seconds: 2),
      freshnessDeadline: const Duration(seconds: 30),
      backoffBase: const Duration(milliseconds: 20),
      backoffCap: const Duration(milliseconds: 200),
      deadlineFloor: const Duration(milliseconds: 50),
    );

/// `RemoteStateMan` wearing the access contract's control surfaces: every
/// `StateManApi` member forwards to the client and travels the in-memory
/// channel; the session lever and the store readouts go straight to the fake —
/// the split `client_harness.dart`'s `RelayServedFake` makes, for its reason:
/// the levers are the plant, and the plant is not something a connected client
/// may drive.
final class _RemoteAccessLeg implements StateManApi, StateManAccessHarness {
  _RemoteAccessLeg(this._client, this._gateway, this._fake);

  final RemoteStateMan _client;
  final _ServedAccessGateway _gateway;
  final FakeAccessServices _fake;

  // ------------------------------------------------ the wire surface, forwarded

  @override
  AccessTemplateApi get accessTemplates => _client.accessTemplates;

  @override
  AccessAdminApi get accessAdmin => _client.accessAdmin;

  @override
  AuditApi get audit => _client.audit;

  @override
  BackendConfigApi get backendConfig => _client.backendConfig;

  @override
  ValueListenable<DynamicValue> listen(String key) => _client.listen(key);

  @override
  Stream<DynamicValue> subscribe(String key) => _client.subscribe(key);

  @override
  DynamicValue? read(String key) => _client.read(key);

  @override
  Future<DynamicValue> readFresh(String key) => _client.readFresh(key);

  @override
  Future<Map<String, DynamicValue>> readMany(List<String> keys) =>
      _client.readMany(keys);

  @override
  Future<WriteResult> write(String key, Object? value,
          {Object? expect, String? cmd}) =>
      _client.write(key, value, expect: expect, cmd: cmd);

  @override
  Future<List<WriteResult>> writeStatus(List<String> cmds) =>
      _client.writeStatus(cmds);

  @override
  Future<HoldHandle> holdToRun(String key) => _client.holdToRun(key);

  @override
  List<String> get keys => _client.keys;

  @override
  BrowseApi get browse => _client.browse;

  @override
  TimeseriesApi get timeseries => _client.timeseries;

  @override
  HistoryViewApi get historyViews => _client.historyViews;

  @override
  PreferencesApi get preferences => _client.preferences;

  // ------------------------------------------- the levers, reached directly

  @override
  void actAs(AccessSession session) => _fake.actAs(session);

  @override
  List<String> get accessStoreWrites => _fake.writes;

  @override
  String? storedPasswordFor(String subject) => _fake.storedPasswordFor(subject);

  @override
  Future<void> dispose() async {
    await _client.dispose();
    await _gateway.dispose();
  }
}

/// How many legs arm 8's checks actually built — the "ran" half of the
/// ledger. Each access check calls `make()` exactly once, so this counter is
/// the number of checks that genuinely started against `RemoteStateMan`.
int _legsBuilt = 0;

/// One leg: a fresh fake, a fresh scripted gateway, a fresh `RemoteStateMan`
/// dialled over the in-memory channel. Synchronous, as the kit requires.
StateManApi _makeLeg() {
  _legsBuilt++;
  final fake = FakeAccessServices();
  final gateway = _ServedAccessGateway(fake);
  final client = RemoteStateMan(
    // Never dialled — the seam below supplies the channel. Carried because
    // the supervisor puts it on the health line.
    uri: Uri.parse('ws://in-memory.invalid:0/access-leg'),
    config: _legConfig(),
    dial: (_) async => gateway.attempt(),
  );
  return _RemoteAccessLeg(client, gateway, fake);
}

// -----------------------------------------------------------------------------
// A client for the getter arm: dead port, answers without a round trip
// -----------------------------------------------------------------------------

RemoteStateMan _deadPortClient() {
  final client = RemoteStateMan(
    // A well-formed ws URI nothing will ever answer; the getters under test
    // answer without a round trip, so the port never matters.
    uri: Uri.parse('ws://127.0.0.1:1/never-dialled'),
    config: _legConfig(),
  );
  addTearDown(client.dispose);
  return client;
}

// -----------------------------------------------------------------------------

void main() {
  group('arm 1: one request, one answer, per member', () {
    test('the table covers the whole of AccessMethods.all', () {
      expect({for (final m in _members) m.wire}, AccessMethods.all,
          reason: 'a member added to AccessMethods without a table row would '
              'ship a proxy nothing pins — the set comparison is what makes '
              'the addition visible here');
    });

    test('every member sends exactly one request under its wire name and '
        'returns the decoded answer', () async {
      for (final member in _members) {
        final recorder = _Recorder((_, __) => member.answer());
        final apis = _Apis(recorder.call);
        final decoded = await member.drive(apis);
        expect(recorder.requests, hasLength(1),
            reason: '${member.wire}: one member is one request — more is a '
                'retry or a fan-out, fewer is an answer invented client-side');
        expect(recorder.requests.single.method, member.wire,
            reason: '${member.wire}: the wire name is AccessMethods\' — a '
                'proxy inventing its own spelling reaches no handler');
        member.check?.call(decoded);
      }
    });
  });

  group('arm 2: THE NO-IDENTITY PIN', () {
    test('no encoded payload carries an identity key, at any depth', () async {
      // Collect the encoded params of every member, as driven by the table.
      final payloads = <({String wire, Map<String, Object?> params})>[];
      for (final member in _members) {
        final recorder = _Recorder((_, __) => member.answer());
        await member.drive(_Apis(recorder.call));
        for (final request in recorder.requests) {
          payloads.add((wire: member.wire, params: request.params));
        }
      }

      for (final payload in payloads) {
        final found =
            _keysOf(payload.params).where(_identityKeys.contains).toSet();
        expect(found, isEmpty,
            reason: '${payload.wire}: the encoded payload carries '
                '$found. 17-03 made an identity parameter unrepresentable in '
                'the interface; a proxy is free to invent a field the '
                'interface never mentioned, and this is the arm that says it '
                'did not. A client that can name the user is a client that '
                'can forge one (ACCESS-06)');
      }

      // Anti-vacuity: the pin must have swept a real surface. Twenty-eight
      // members drove at least twenty-eight payloads; a sweep over fewer than
      // twenty-six saw less than the wire and proved nothing about the rest.
      expect(payloads.length, greaterThan(25),
          reason: 'the identity pin ran over ${payloads.length} encoded '
              'payloads; a pin that reflects over nothing reports no '
              'forbidden field, and only this half can see that');
    });
  });

  group('arm 3: a forbidden becomes AccessDenied, one arm per family', () {
    // One gated member per family, refused and then answered — the refusal
    // must arrive as the SAME type a direct-mode refusal throws, and the
    // success control is what stops a wrapper that throws on everything
    // passing the four refusal halves.
    final perFamily = <String, ({_Member member, Object? ok})>{
      'templates': (
        member: _members.firstWhere(
            (m) => m.wire == AccessMethods.templateCreate),
        ok: null
      ),
      'admin': (
        member: _members.firstWhere(
            (m) => m.wire == AccessMethods.adminCreateRole),
        ok: null
      ),
      'audit': (
        member:
            _members.firstWhere((m) => m.wire == AccessMethods.auditEntries),
        ok: <Object?>[]
      ),
      'config': (
        member: _members.firstWhere((m) => m.wire == AccessMethods.configWrite),
        ok: null
      ),
    };

    perFamily.forEach((family, row) {
      test('$family: the refusal is an AccessDenied, and the same member '
          'answers normally when permitted', () async {
        final refusing = _Recorder((method, _) => throw rpc.RpcException(
              _forbidden,
              'AccessDenied: "$method" requires the users group. The call '
              '$_refusalWording.',
              data: {'itemKey': method, 'group': 'users'},
            ));
        await expectLater(
            row.member.drive(_Apis(refusing.call)), throwsA(isA<AccessDenied>()),
            reason: '$family: a gateway refusal must be the same exception '
                'type a direct-mode refusal throws, or every screen grows a '
                'second catch clause and the two transports behave '
                'differently where operators see it');

        // The anti-vacuity half: the same member, permitted, returns.
        final permitted = _Recorder((_, __) => row.ok);
        await row.member.drive(_Apis(permitted.call));
        expect(permitted.requests, hasLength(1),
            reason: '$family: the permitted control did not reach the wire, '
                'so the refusal above may be a wrapper that throws on '
                'everything');
      });
    });
  });

  group('arm 4: the refusal carries its reason through', () {
    test('the gateway\'s own wording survives into the AccessDenied', () async {
      const message = 'AccessDenied: "accessAdmin.createRole" requires the '
          'users group. The call definitively had no effect and must not be '
          'retried.';
      final recorder = _Recorder((_, __) => throw rpc.RpcException(
          _forbidden, message,
          data: {'itemKey': 'accessAdmin.createRole', 'group': 'users'}));

      Object? caught;
      try {
        await _Apis(recorder.call).admin.createRole(_role);
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AccessDenied>());
      expect('$caught', contains(_refusalWording),
          reason: 'the operator must read the same sentence whichever '
              'transport refused it — a refusal stripped to its type loses '
              'the half that says the call had no effect and must not be '
              'retried');
      expect('$caught', contains('accessAdmin.createRole'),
          reason: 'a refusal that does not say what it refused is one nobody '
              'can act on');
    });
  });

  group('arm 5: no retry, no queue, no resend', () {
    test('after a refusal the recorded request count is exactly one',
        () async {
      final recorder = _Recorder((method, _) => throw rpc.RpcException(
          _forbidden, 'refused; the call $_refusalWording.',
          data: {'itemKey': method, 'group': 'users'}));
      final apis = _Apis(recorder.call);

      await expectLater(
          apis.templates.create(_template), throwsA(isA<AccessDenied>()));
      expect(recorder.requests, hasLength(1),
          reason: 'a forbidden is definitive: the gateway said the call had '
              'no effect and must not be retried, and a proxy hammering a '
              'gate it can never pass is the DoS the threat model names '
              '(T-17-08b)');
    });

    test('after a transport error mid-call it is also exactly one — the '
        'proxy propagates and does not resend', () async {
      // The shape json_rpc_2 reports a lost link as (failure_taxonomy.dart's
      // measured table): a StateError, not an RpcException.
      final recorder = _Recorder((_, __) => throw StateError(
          'The client closed with pending request "accessAdmin.createRole".'));
      final apis = _Apis(recorder.call);

      await expectLater(
          apis.admin.createRole(_role), throwsA(isA<StateError>()),
          reason: 'a transport error is not the proxy\'s to translate — the '
              'caller\'s failure taxonomy owns that seam');
      expect(recorder.requests, hasLength(1),
          reason: 'a retry after a timeout is the plausible mistake: the '
              'first request may have LANDED, and re-sending it is a second '
              'administration of the same change. The refusal half above is '
              'the different (and worse) bug — the two must stay separable');
    });
  });

  group('arm 6: a domain error crosses as a structured payload', () {
    test('a TemplateInUse-shaped error keeps its fields, and is not an '
        'AccessDenied', () async {
      // The domain exceptions live in tfc_dart, which this package may not
      // import — so they cross as a typed protocol error (the RpcException,
      // code + data) and the APP maps the payload back to the concrete
      // exception type in 17-12, where tfc_dart is available.
      const data = {
        'code': 'template_in_use',
        'templateName': 'conveyor-1',
        'boundKeys': ['ST101.CN01.MOT01', 'ST201.CN04.MOT01'],
      };
      final recorder = _Recorder((_, __) => throw rpc.RpcException(
          _handlerFailed,
          'accessTemplates.delete failed: "conveyor-1" is bound',
          data: data));

      Object? caught;
      try {
        await _Apis(recorder.call).templates.delete('conveyor-1');
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<rpc.RpcException>(),
          reason: 'the typed protocol error is the carrier 17-12 decodes; '
              'anything flatter loses the fields the message needs');
      expect(caught, isNot(isA<AccessDenied>()),
          reason: 'a domain rule is not an authorisation verdict: the session '
              'WAS allowed, the data refused (D-09\'s other half)');
      final payload = (caught! as rpc.RpcException).data;
      expect(payload, isA<Map<Object?, Object?>>(),
          reason: 'flattened to a string, the template name and the bound key '
              'list are prose nobody can decode');
      final map = payload! as Map;
      expect(map['code'], 'template_in_use');
      expect(map['templateName'], 'conveyor-1');
      expect(map['boundKeys'], ['ST101.CN01.MOT01', 'ST201.CN04.MOT01'],
          reason: 'the bound key list must survive the wire with its '
              'elements intact — it is what the app\'s error dialog shows');
    });
  });

  group('arm 7: StateManApi\'s four getters return the proxies', () {
    test('all four are non-null proxies on a RemoteStateMan', () {
      final client = _deadPortClient();
      expect(client.accessTemplates, isA<AccessTemplateApi>());
      expect(client.accessAdmin, isA<AccessAdminApi>());
      expect(client.audit, isA<AuditApi>());
      expect(client.backendConfig, isA<BackendConfigApi>());
    });

    test('each getter answers the same instance every time', () {
      final client = _deadPortClient();
      expect(identical(client.accessTemplates, client.accessTemplates), isTrue);
      expect(identical(client.accessAdmin, client.accessAdmin), isTrue);
      expect(identical(client.audit, client.audit), isTrue);
      expect(identical(client.backendConfig, client.backendConfig), isTrue,
          reason: 'the history-view proxies are built once and kept '
              '(remote_state_man.dart\'s sub-API block); a fresh proxy per '
              'read would be a different shape for no reason');
    });
  });

  // ---------------------------------------------------------------- arm 8
  //
  // The contract suite against RemoteStateMan over the in-memory channel.
  // This is ACCESS-02's client half; the full WebSocket leg — a real
  // RelayServer with the real policy gate — is 17-14's.
  group('arm 8: the access contract over RemoteStateMan', () {
    runAccessContract(_makeLeg, supportsAccessControl: true);

    // Declared AFTER the contract group so it runs after every check has
    // (concurrency 1, in-file declaration order): the ledger reads what the
    // run itself did, not what it intended.
    test('LEDGER: the leg ran the whole access roster with an empty gap', () {
      // The declared count, reconciled against the in-memory leg's:
      // access_contract_meta_test.dart pins `_declaredAccessCheckCount = 29`
      // — 27 until the page-visibility whitelist merged in and added
      // setRolePages and setUserPages. If the kit's roster moves, this
      // literal must move with it — deliberately, on the record.
      expect(accessChecks.length, 29,
          reason: 'the in-memory leg declares 29 access checks; this leg '
              'must judge the same roster, not a subset that happens to be '
              'green');
      expect(_legsBuilt, accessChecks.length,
          reason: 'each access check builds exactly one leg, so this counter '
              'is the number of checks that actually STARTED against '
              'RemoteStateMan. A leg silently running half the suite is '
              'exactly what this arithmetic exists to catch (T-17-08d)');
      // The gap, as a set: registration iterates the kit's own const map, so
      // a by-name gap can only open if the run above skipped — and the count
      // reconciliation is what would catch it.
      final gap = _legsBuilt >= accessChecks.length
          ? const <String>{}
          : accessChecks.keys.toSet();
      expect(gap, isEmpty,
          reason: 'ACCESS-02\'s client half requires an EMPTY gap list on '
              'this leg — a named gap here belongs to the ws legs until '
              '17-14 empties them');
    });
  });
}

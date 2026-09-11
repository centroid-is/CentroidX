@TestOn('vm')

/// The relayed access stores in isolation: the protocol-error mapping, the
/// wire↔store shape conversions, and the gateway-mode sink (17-12).
///
/// The transport itself is proven by
/// `test/providers/gateway_access_route_test.dart` over a real socket; these
/// arms hold the pieces still while they are measured — a typed fake per
/// family, no socket, no container.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:tfc/core/relayed_access_stores.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_template_store.dart';
import 'package:tfc_dart/core/access/audit_trail_store.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

// -----------------------------------------------------------------------------
// The declared registry, held against the wire convention
// -----------------------------------------------------------------------------

/// The five domain codes the wire convention carries (17-08 arm 6's shape;
/// `access_api.dart` declares no error DTO yet — F-2's queued follow-up).
/// This is the *test's* copy, so the registry drifting in either direction
/// reddens an arm: a code added there without landing here is a mapping
/// nobody reviewed, and one removed there is a type silently lost.
const Set<String> _wireCodes = {
  'template_in_use',
  'template_not_found',
  'template_exists',
  'invalid_template_name',
  'binding_not_found',
};

/// What each code must decode to — consulted from the iteration arm, so the
/// *coverage* claim is made by iterating [kAccessDomainErrorFactories]
/// itself, never by a hand-kept list of asserts.
const Map<String, Type> _expectedTypes = {
  'template_in_use': TemplateInUseException,
  'template_not_found': TemplateNotFoundException,
  'template_exists': TemplateExistsException,
  'invalid_template_name': InvalidTemplateNameException,
  'binding_not_found': BindingNotFoundException,
};

/// A payload carrying every field any code reads, so no factory can pass by
/// luckily reading a field another code's payload happened to share.
const Map<String, Object?> _fullPayloadFields = {
  'templateName': 'conveyor-1',
  'boundKeys': ['ST101.CN01.MOT01', 'ST201.CN04.MOT01'],
  'keyName': 'ST101.CN01.MOT01',
};

rpc.RpcException _domainError(String code) => rpc.RpcException(
      -32011,
      'the far end refused: $code',
      data: {'code': code, ..._fullPayloadFields},
    );

// -----------------------------------------------------------------------------
// Typed fakes
// -----------------------------------------------------------------------------

/// An [AccessTemplateApi] that throws what the script says, records nothing.
final class _ThrowingTemplateApi implements AccessTemplateApi {
  _ThrowingTemplateApi(this._error);
  final Object Function() _error;

  Never _throw() => throw _error();

  @override
  Future<List<AccessTemplate>> list() async => _throw();
  @override
  Future<Map<String, String>> bindings() async => _throw();
  @override
  Future<List<String>> keysBoundTo(String templateName) async => _throw();
  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      _throw();
  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      _throw();
  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      _throw();
  @override
  Future<void> delete(String name, {String? reason}) async => _throw();
  @override
  Future<void> bind(String keyName, String templateName,
          {String? reason}) async =>
      _throw();
  @override
  Future<void> unbind(String keyName, {String? reason}) async => _throw();
}

/// An [AccessTemplateApi] answering fixed data.
final class _ServingTemplateApi implements AccessTemplateApi {
  _ServingTemplateApi(this.templates);
  final List<AccessTemplate> templates;

  @override
  Future<List<AccessTemplate>> list() async => templates;
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

/// An [AccessAdminApi] recording the one params object that matters and
/// answering fixed users.
final class _RecordingAdminApi implements AccessAdminApi {
  NewUserParams? createdUser;
  SetUserPasswordParams? passwordReset;
  ({String subject, String newRole, String? reason})? roleMove;
  List<UserSummary> users = const [];

  @override
  Future<List<AccessRole>> roles() async => const [];
  @override
  Future<List<UserSummary>> listUsers() async => users;
  @override
  Future<void> createRole(AccessRole role, {String? reason}) async {}
  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async {}
  @override
  Future<void> deleteRole(String name, {String? reason}) async {}
  @override
  Future<void> renameRole(String from, String to, {String? reason}) async {}
  @override
  Future<void> createUser(NewUserParams params) async => createdUser = params;
  @override
  Future<void> deleteUser(String subject, {String? reason}) async {}
  @override
  Future<void> setUserRole(String subject, String newRole,
          {String? reason}) async =>
      roleMove = (subject: subject, newRole: newRole, reason: reason);
  @override
  Future<void> setUserStationAccount(String subject, bool value,
      {String? reason}) async {}
  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async =>
      passwordReset = params;
}

/// An [AuditApi] recording the query it was sent and answering fixed rows.
final class _RecordingAuditApi implements AuditApi {
  AuditQueryParams? lastQuery;
  List<String>? lastActionIds;
  List<AuditRecord> rows = const [];

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async {
    lastQuery = query;
    return rows;
  }

  @override
  Future<Map<String, int>> memberCountsByAction(
      List<String> actionIds) async {
    lastActionIds = actionIds;
    return {for (final id in actionIds) id: 1};
  }

  @override
  Future<List<String>> distinctWho() async => const ['ST101-panel'];
}

final AccessTemplate _templateA = AccessTemplate(name: 'conveyor-1', rules: {
  kWholeKeyMember: AccessGroup.setpoints,
});
final AccessTemplate _templateB = AccessTemplate(name: 'freezer-door', rules: {
  kWholeKeyMember: AccessGroup.configure,
});

void main() {
  // ---------------------------------------------------------------------------
  // The mapping table
  // ---------------------------------------------------------------------------

  group('the domain-error mapping', () {
    test(
        'is exhaustive: every code in the registry decodes to its concrete '
        'type, never the generic carrier — proven by iterating the registry',
        () {
      expect(kAccessDomainErrorFactories.keys.toSet(), _wireCodes,
          reason: 'the registry and the wire convention must not drift in '
              'either direction');
      for (final code in kAccessDomainErrorFactories.keys) {
        final mapped = domainExceptionFor(_domainError(code));
        expect(mapped, isNotNull, reason: 'code "$code" fell through');
        expect(mapped, isNot(isA<RelayedAccessException>()),
            reason: 'code "$code" mapped to the generic carrier — a declared '
                'code flattened is a screen that says less than it could');
        expect(mapped.runtimeType, _expectedTypes[code],
            reason: 'code "$code" decoded to the wrong type');
      }
    });

    test('template_in_use keeps the template name AND the bound keys', () {
      final mapped =
          domainExceptionFor(_domainError('template_in_use'))!;
      final domain = mapped as TemplateInUseException;
      expect(domain.templateName, 'conveyor-1');
      expect(domain.boundKeys, ['ST101.CN01.MOT01', 'ST201.CN04.MOT01'],
          reason: '"still bound to 2 keys" is the sentence the screen can '
              'only say if the list survives');
    });

    test('binding_not_found carries the key name', () {
      final mapped =
          domainExceptionFor(_domainError('binding_not_found'))!;
      expect((mapped as BindingNotFoundException).keyName,
          'ST101.CN01.MOT01');
    });

    test(
        'an unrecognised code is a named RelayedAccessException carrying the '
        'raw code — never a swallow', () {
      final mapped = domainExceptionFor(rpc.RpcException(
          -32011, 'the far end refused: quota_exceeded',
          data: const {'code': 'quota_exceeded', 'limit': 100}));
      expect(mapped, isA<RelayedAccessException>(),
          reason: 'an unmapped code is a bug in the registry and must be '
              'visible as one');
      final unmapped = mapped! as RelayedAccessException;
      expect(unmapped.code, 'quota_exceeded');
      expect('$unmapped', contains('quota_exceeded'));
    });

    test(
        'an RpcException with no domain payload propagates unchanged — '
        '"you cannot yet" stays distinguishable from "the data refused"',
        () async {
      final infra = rpc.RpcException(-32011, 'accessTemplates.list failed',
          data: const {'method': 'accessTemplates.list', 'request': 'omitted'});
      expect(domainExceptionFor(infra), isNull);
      Object? caught;
      try {
        await relayedAccessErrors<void>(() async => throw infra);
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, same(infra),
          reason: 'an infrastructure failure re-wrapped as a domain error '
              'would tell the operator the data refused when the server '
              'broke');
    });
  });

  // ---------------------------------------------------------------------------
  // The refusal callback
  // ---------------------------------------------------------------------------

  group('AccessDenied through the adapters', () {
    test(
        'passes through untouched (the client already mapped forbidden) and '
        'fires onDenied before the rethrow, like the direct store', () async {
      const denial = AccessDenied('access.template.conveyor-1',
          AccessGroup.users);
      final seen = <AccessDenied>[];
      final store = RelayedAccessTemplateStore(
        api: _ThrowingTemplateApi(() => denial),
        onDenied: seen.add,
      );

      Object? caught;
      try {
        await store.create(_templateA);
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, same(denial),
          reason: 'mapping it twice would replace the client\'s message-'
              'carrying subtype with something flatter');
      expect(seen, [same(denial)],
          reason: 'the shared denial prompt hangs off this callback, and it '
              'must appear even at a call site that swallows the exception');
    });

    test('a domain error does NOT fire onDenied — the session was allowed, '
        'the data refused', () async {
      final seen = <AccessDenied>[];
      final store = RelayedAccessTemplateStore(
        api: _ThrowingTemplateApi(() => _domainError('template_in_use')),
        onDenied: seen.add,
      );

      await expectLater(
          store.delete('conveyor-1'), throwsA(isA<TemplateInUseException>()));
      expect(seen, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Shape conversions
  // ---------------------------------------------------------------------------

  group('the template adapter', () {
    test('template(name) is derived from list() — the wire has no single-row '
        'read', () async {
      final store = RelayedAccessTemplateStore(
          api: _ServingTemplateApi([_templateA, _templateB]));
      expect((await store.template('freezer-door'))?.name, 'freezer-door');
      expect(await store.template('no-such-template'), isNull);
    });
  });

  group('the admin adapter', () {
    test('createUser and setUserPassword travel as the withholding params '
        'objects, on the wire vocabulary (subject/grantedRole)', () async {
      final api = _RecordingAdminApi();
      final store = RelayedAccessAdminStore(api: api);

      await store.createUser(
          username: 'jon',
          password: 's3cret',
          roleName: 'Engineering',
          reason: 'commissioning');
      expect(api.createdUser?.subject, 'jon');
      expect(api.createdUser?.grantedRole, 'Engineering');
      expect(api.createdUser?.password, 's3cret');
      expect(api.createdUser?.reason, 'commissioning');
      expect('${api.createdUser}', isNot(contains('s3cret')),
          reason: 'the params class withholds the credential from toString');

      await store.setUserPassword('jon', 'n3w-secret');
      expect(api.passwordReset?.subject, 'jon');
      expect(api.passwordReset?.password, 'n3w-secret');

      await store.setUserRole('jon', 'Operator', reason: 'demotion');
      expect(api.roleMove, (subject: 'jon', newRole: 'Operator',
          reason: 'demotion'));
    });

    test(
        'listUsers carries both timestamps across and still carries no '
        'credential',
        () async {
      final created = DateTime.utc(2026, 4, 1, 7, 30);
      final lastLogin = DateTime.utc(2026, 9, 8, 6, 15);
      final api = _RecordingAdminApi()
        ..users = [
          UserSummary(
              username: 'ST101-panel',
              roleName: 'Panel Operator',
              displayName: 'ST101',
              stationAccount: true,
              createdAt: created,
              lastLoginAt: lastLogin),
        ];
      final store = RelayedAccessAdminStore(api: api);

      final rows = await store.listUsers();
      final row = rows.single;
      expect(row.username, 'ST101-panel');
      expect(row.roleName, 'Panel Operator');
      expect(row.stationAccount, isTrue);
      expect(row.createdAt, created,
          reason: 'the created column is the whole of 17-08 F-1: it read '
              '1970-01-01 on every gateway station before the wire carried it');
      expect(row.lastLoginAt, lastLogin);
      // There is no credential column left to assert about — `UserSummary`
      // declares none, which is what stopped a gateway panel from having to
      // mint one. The row is the wire's own object, untouched.
      expect(row, same(api.users.single));
    });

    test('an account with no password arrives marked, and the screen reads '
        'the bit rather than decoding a column', () async {
      final api = _RecordingAdminApi()
        ..users = const [
          UserSummary(
              username: 'line', roleName: 'Operator', hasPassword: false),
          UserSummary(username: 'jon', roleName: 'Engineering'),
        ];
      final store = RelayedAccessAdminStore(api: api);

      final rows = await store.listUsers();
      final open = rows.firstWhere((r) => r.username == 'line');
      final closed = rows.firstWhere((r) => r.username == 'jon');

      expect(open.hasPassword, isFalse,
          reason: 'the users screen reads this bit directly now. It used to '
              'ask isPasswordless() about a passwordHash the panel had just '
              'fabricated from this same bit, which is a round trip through a '
              'synthetic credential to recover what the wire already said.');
      expect(closed.hasPassword, isTrue);
    });

    test(
        'a backend that sends no createdAt still renders as a visible absence, '
        'never as a plausible date', () async {
      final api = _RecordingAdminApi()
        ..users = const [
          // What a backend older than the DTO answers: no timestamp keys at
          // all, which decode to null.
          UserSummary(
              username: 'ST101-panel',
              roleName: 'Panel Operator',
              stationAccount: true),
        ];
      final store = RelayedAccessAdminStore(api: api);

      final row = (await store.listUsers()).single;
      expect(row.createdAt, isNull,
          reason: 'the absence survives as an absence. It used to become an '
              'epoch-zero sentinel because the drift row could not hold a '
              'null, and the roster drew 1970-01-01; the screen now renders '
              'it as unknown, which is what it actually is.');
      expect(row.lastLoginAt, isNull,
          reason: 'null is the honest floor and the screen renders it as '
              '"never"');
    });
  });

  group('the audit adapter', () {
    test('an AuditQuery crosses field for field, instants as epoch ms UTC',
        () async {
      final api = _RecordingAuditApi();
      final store = RelayedAuditTrailStore(api: api);
      final window = AuditWindow(
        start: DateTime.utc(2026, 8, 25),
        end: DateTime.utc(2026, 9, 1),
      );

      await store.entries(AuditQuery(
        window: window,
        before: DateTime.utc(2026, 8, 30),
        keyPrefix: 'ST101.',
        who: 'jon',
        groupNames: const ['configure', 'setpoints'],
        includeAuth: true,
        outcome: AuditOutcomeFilter.deniedOnly,
        limit: 250,
      ));

      final sent = api.lastQuery!;
      expect(sent.startMs, window.start.millisecondsSinceEpoch);
      expect(sent.endMs, window.end.millisecondsSinceEpoch);
      expect(sent.beforeMs,
          DateTime.utc(2026, 8, 30).millisecondsSinceEpoch);
      expect(sent.keyPrefix, 'ST101.');
      expect(sent.who, 'jon');
      expect(sent.groupNames, ['configure', 'setpoints']);
      expect(sent.includeAuth, isTrue);
      expect(sent.allowed, isFalse,
          reason: 'deniedOnly is the nullable bool\'s false');
      expect(sent.limit, 250);
    });

    test('the whole-table search escape survives: a null window crosses as '
        'neither bound', () async {
      final api = _RecordingAuditApi();
      await RelayedAuditTrailStore(api: api)
          .entries(AuditQuery(keyPrefix: 'ST101.'));
      expect(api.lastQuery!.startMs, isNull);
      expect(api.lastQuery!.endMs, isNull);
    });

    test('the three outcome states map to the three nullable-bool values',
        () {
      expect(wireAllowedFor(AuditOutcomeFilter.any), isNull);
      expect(wireAllowedFor(AuditOutcomeFilter.allowedOnly), isTrue);
      expect(wireAllowedFor(AuditOutcomeFilter.deniedOnly), isFalse);
    });

    test('the wire rows reach the caller untouched, as the same objects',
        () async {
      final api = _RecordingAuditApi()
        ..rows = [
          AuditRecord(
            at: DateTime.utc(2026, 9, 1, 12),
            who: 'ST101-panel',
            station: 'ST101',
            roleName: 'Panel Operator',
            surface: 'tag',
            itemKey: 'ST101.CN01.MOT01',
            member: 'p_set_Speed',
            oldValue: '40',
            newValue: '55',
            groupRequired: 'setpoints',
            allowed: false,
            origin: 'relay',
            actionId: 'A-1',
            reason: 'test',
          ),
          AuditRecord(
            at: DateTime.utc(2026, 9, 1, 13),
            who: 'jon',
            station: 'ST101',
            roleName: 'Engineering',
            surface: 'pref',
            itemKey: 'key_mappings',
            groupRequired: 'configure',
            allowed: true,
            actionId: 'A-2',
          ),
        ];
      final rows = await RelayedAuditTrailStore(api: api)
          .entries(AuditQuery());

      expect(rows, hasLength(2));
      expect(rows.first.who, 'ST101-panel');
      expect(rows.first.member, 'p_set_Speed');
      expect(rows.first.oldValue, '40');
      expect(rows.first.newValue, '55');
      expect(rows.first.allowed, isFalse);
      expect(rows.first.origin, 'relay');
      expect(rows.first.actionId, 'A-1');
      expect(rows.first.reason, 'test');
      // The store is a pass-through, and this is what pins it there: the very
      // objects the wire produced reach the caller. It used to rebuild each row
      // as a drift `AuditEntryData` with an invented ordinal id, and the
      // assertion here was that those ordinals were distinct — a fact about a
      // fabrication. Reintroducing any reconstruction, however faithful,
      // reddens this, because a copy is not the same instance.
      expect(rows[0], same(api.rows[0]));
      expect(rows[1], same(api.rows[1]));
    });

    test('memberCountsByAction accepts any iterable, sends a list', () async {
      final api = _RecordingAuditApi();
      final counts = await RelayedAuditTrailStore(api: api)
          .memberCountsByAction({'A-1', 'A-2'}.where((_) => true));
      expect(api.lastActionIds, ['A-1', 'A-2']);
      expect(counts, {'A-1': 1, 'A-2': 1});
    });
  });

  // ---------------------------------------------------------------------------
  // The gateway-mode sink
  // ---------------------------------------------------------------------------

  group('ServerAuditedSink', () {
    test('cannot stall a plant write: record completes at once, awaiting '
        'nothing', () async {
      const sink = ServerAuditedSink();
      var completed = false;
      final pending = sink
          .record(AuditRecord.login(
            who: 'jon',
            station: 'ST101',
            roleName: 'Engineering',
            actionId: 'A-sink',
          ))
          .then((_) => completed = true);
      // One microtask flush and no timer: a record that reached for the
      // event loop — a socket, a deadline, anything awaitable — is a record
      // that can hold a jog hostage.
      await Future.microtask(() {});
      await Future.microtask(() {});
      expect(completed, isTrue,
          reason: 'the sink must resolve without the event loop turning — '
              'sabotage: make record await anything and this reddens');
      await pending.timeout(const Duration(milliseconds: 100));
    });

    test('is a distinct type from NullAuditSink — the third case is named, '
        'not silent', () {
      const sink = ServerAuditedSink();
      expect(sink, isNot(isA<NullAuditSink>()),
          reason: 'NullAuditSink means "knowingly no trail"; a gateway panel '
              'has a trail, at the far end, and the type is how a test or a '
              'screen tells the cases apart');
      expect(sink, isA<AuditSink>());
    });
  });
}

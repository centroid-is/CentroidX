@TestOn('vm')

/// 17-12: the access surfaces follow the transport, measured with Postgres
/// unreachable.
///
/// Criterion 1's actual measurement: *"proven with the panel's direct database
/// route unavailable, not merely unused. It works when Postgres is
/// **unreachable**, since a route that exists will be taken."* Every gateway
/// arm here therefore runs with `databaseProvider` overridden to **null** and,
/// separately, to **throwing** — "no database configured" and "the database is
/// down" are different states and a provider can be null-safe and still
/// propagate an exception from a `watch` it did not need.
///
/// The far end is `test/helpers/scripted_gateway.dart` on a real loopback
/// socket, for `gateway_link_test.dart`'s stated reason: the app cannot fake a
/// `RemoteStateMan` connection, it can only make one. Every arm is a plain
/// `test()`, never a widget test — the widget binding's fake-async zone will
/// not pump a real socket's completions.
///
/// **The audit sink needs the most words** (criterion 3). In gateway mode the
/// backend's policy decorator writes the audit row for every relayed
/// operation, attributed to the identity the server verified at `hello`
/// (D-05/D-11) — the wire deliberately has **no** audit-record method, because
/// a method a client could write an arbitrary row through would be a forgery
/// surface. So the gateway-mode sink does not relay rows; what it must not do
/// is quietly become [NullAuditSink], because a `NullAuditSink` on a gateway
/// panel is indistinguishable from a working trail on every screen. Arm 4
/// asserts the sink is a *distinct, named* thing in gateway mode, and its
/// anti-vacuity half asserts the two real `NullAuditSink` cases its doc names
/// are unchanged.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/gateway_config.dart';
import 'package:tfc/providers/access.dart';
import 'package:tfc/providers/access_admin.dart';
import 'package:tfc/providers/access_templates.dart';
import 'package:tfc/providers/audit_trail.dart';
import 'package:tfc/providers/collector.dart';
import 'package:tfc/providers/database.dart';
import 'package:tfc/providers/preferences.dart';
import 'package:tfc/providers/state_man.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';
import 'package:tfc_dart/core/access/access_template_store.dart';
import 'package:tfc_dart/core/access/audit_trail_store.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;
import 'package:tfc_dart/core/preferences.dart';
import 'package:tfc_dart/core/state_man.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart'
    show defaultPageSubscription;
// `PreferencesApi` is spelled in both packages; this file wants `tfc_dart`'s.
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart'
    hide PreferencesApi;

import '../helpers/scripted_gateway.dart';
import '../helpers/test_helpers.dart';

// -----------------------------------------------------------------------------
// The wire error codes, spelled locally
// -----------------------------------------------------------------------------

/// The gateway's `ServerErrorCodes.forbidden`. Two literals in two files that
/// an arm fails the moment they disagree — `client_sub_apis.dart:548`'s own
/// discipline, driven from the far side.
const int _forbidden = -32005;

/// The gateway's `ServerErrorCodes.handlerFailed` — the carrier a *domain*
/// refusal travels under, per 17-08's arm 6. Deliberately not [_forbidden]:
/// "you may not" and "the data refused" must stay distinguishable.
const int _handlerFailed = -32011;

/// The wording a gateway refusal carries, which must survive to the operator
/// whichever transport refused it (17-08 deviation 4: `RemoteAccessDenied`
/// carries the gateway's own sentence).
const String _refusalWording =
    'definitively had no effect and must not be retried';

// -----------------------------------------------------------------------------
// Fixtures the scripted gateway serves
// -----------------------------------------------------------------------------

final AccessTemplate _servedTemplate =
    AccessTemplate(name: 'conveyor-1', rules: const {
  kWholeKeyMember: AccessGroup.setpoints,
});

const AccessRole _servedRole = AccessRole(
  name: 'Panel Operator',
  groups: {AccessGroup.operate, AccessGroup.setpoints},
);

const AuthenticatedUser _servedUser = AuthenticatedUser(
  username: 'ST101-panel',
  roleName: 'Panel Operator',
  displayName: 'ST101 panel',
  stationAccount: true,
);

final AuditRecord _servedRow = AuditRecord(
  at: DateTime.utc(2026, 9, 1, 12, 0),
  who: 'ST101-panel',
  station: 'ST101',
  roleName: 'Panel Operator',
  surface: 'tag',
  itemKey: 'ST101.CN01.MOT01',
  member: 'p_set_Speed',
  oldValue: '40',
  newValue: '55',
  groupRequired: 'setpoints',
  allowed: true,
  origin: 'relay',
  actionId: 'A-17-12',
);

/// This station's mapping. It names [kScriptedSeededKey] because
/// `GatewayStateMan` fixes the client's subscription set from the mapping at
/// construction.
final KeyMappings _mappings = KeyMappings(nodes: {
  kScriptedSeededKey: KeyMappingEntry(
      opcuaNode: OpcUANodeConfig(namespace: 2, identifier: 'Connected')),
});

// -----------------------------------------------------------------------------
// The scripted gateway
// -----------------------------------------------------------------------------

/// How one access method is answered.
typedef _Answer = void Function(ScriptedLink link, int id);

/// A JSON-RPC error **with a `data` payload** — [ScriptedLink.error] cannot
/// carry one, and the domain-error arm is entirely about the payload, so this
/// writes the frame raw. The socket is public on [ScriptedLink] for exactly
/// this kind of arm.
void _errorWithData(ScriptedLink link, int id, int code, String message,
        Map<String, Object?> data) =>
    link.socket.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message, 'data': data},
    }));

/// A gateway that completes the handshake, seeds the subscription snapshot,
/// and answers the access families from [answers]. An unscripted access
/// request gets **no answer**, so an arm that forgot to script one fails
/// loudly on its own deadline rather than passing on a default.
Future<ScriptedGateway> _gateway(Map<String, _Answer> answers) =>
    ScriptedGateway.start((link, method, id) {
      if (method == Methods.hello) return link.hello(id);
      if (method == Methods.subscribe) {
        return link.snapshot(id, defaultPageSubscription);
      }
      answers[method]?.call(link, id);
    });

/// The four families answering their happy-path data.
Map<String, _Answer> _servedFamilies({AccessTemplate? template}) {
  final served = template ?? _servedTemplate;
  return {
    AccessMethods.templateList: (link, id) =>
        link.result(id, [accessTemplateToJson(served)]),
    AccessMethods.templateBindings: (link, id) =>
        link.result(id, {'ST101.CN01.MOT01': served.name}),
    AccessMethods.templateKeysBoundTo: (link, id) =>
        link.result(id, ['ST101.CN01.MOT01']),
    AccessMethods.adminRoles: (link, id) =>
        link.result(id, [accessRoleToJson(_servedRole)]),
    AccessMethods.adminListUsers: (link, id) =>
        link.result(id, [authenticatedUserToJson(_servedUser)]),
    AccessMethods.auditEntries: (link, id) =>
        link.result(id, [auditRecordToJson(_servedRow)]),
    AccessMethods.auditMemberCountsByAction: (link, id) =>
        link.result(id, {'A-17-12': 3}),
    AccessMethods.auditDistinctWho: (link, id) =>
        link.result(id, ['ST101-panel']),
  };
}

// -----------------------------------------------------------------------------
// The provider stacks
// -----------------------------------------------------------------------------

/// The full provider stack a gateway panel runs, with nothing about the
/// transport faked — `gateway_link_test.dart`'s harness, with the database
/// override a parameter because this file's whole point is what happens when
/// it is null and when it throws.
Future<ProviderContainer> _gatewayPanel(
  ScriptedGateway gateway, {
  required Future<Database?> Function() database,
  InMemoryPreferences? local,
}) async {
  final store = local ?? InMemoryPreferences();
  await writeGatewayConfig(
      store,
      GatewayConfig(
          mode: TransportMode.gateway, url: gateway.uri.toString()));
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      systemPreferencesProvider.overrideWith((ref) => createTestPreferences(
            keyMappings: _mappings,
            stateManConfig: StateManConfig(opcua: const []),
          )),
      localPreferencesProvider.overrideWithValue(store),
      databaseProvider.overrideWith((ref) => database()),
      stationNameProvider.overrideWithValue('phase17-panel'),
      collectorProvider.overrideWith((ref) async => null),
      // A gateway station building a *local* StateMan is a defect in itself.
      stateManFactoryProvider.overrideWithValue(({
        required StateManConfig config,
        required KeyMappings keyMappings,
        List<DeviceClient> deviceClients = const [],
      }) async =>
          throw StateError('local StateMan construction reached')),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A direct-mode container: no gateway row, so the config falls back to
/// direct, and the transport plumbing is never touched.
ProviderContainer _directContainer({required Future<Database?> Function() database}) {
  final container = ProviderContainer(
    overrides: [
      localPreferencesProvider.overrideWithValue(InMemoryPreferences()),
      databaseProvider.overrideWith((ref) => database()),
      stationNameProvider.overrideWithValue('phase17-panel'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// An in-memory database whose teardown is registered at acquisition.
Database _testDatabase() {
  final appDb = AppDatabase.inMemoryForTest();
  final db = Database(appDb);
  addTearDown(() async {
    await db.dispose();
    await appDb.close();
  });
  return db;
}

/// A `databaseProvider` body for "the database is down": not null — a route
/// that *exists* and *throws*, which is the state a provider that watched it
/// needlessly propagates.
Future<Database?> _throwingDatabase() async =>
    throw StateError('postgres unreachable: connection refused');

void main() {
  // ---------------------------------------------------------------------------
  // Arms 1-4: gateway mode, databaseProvider == null
  // ---------------------------------------------------------------------------

  group('gateway mode with NO database (databaseProvider null)', () {
    test('arm 1: templates work — the store is non-null and list() answers '
        'what the gateway served', () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final store =
          await container.read(accessTemplateStoreProvider.future);
      expect(store, isNotNull,
          reason: 'a null store renders the templates screen "unavailable" '
              'on a panel whose gateway is serving them right now');
      final templates = await store!.list();
      expect(templates.map((t) => t.name), ['conveyor-1']);
      final bindings = await store.bindings();
      expect(bindings, {'ST101.CN01.MOT01': 'conveyor-1'});
    });

    test('arm 2: roles and users work through accessAdminStoreProvider',
        () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final store = await container.read(accessAdminStoreProvider.future);
      expect(store, isNotNull);
      final roles = await store!.roles();
      expect(roles.map((r) => r.name), ['Panel Operator']);
      final users = await store.listUsers();
      expect(users.map((u) => u.username), ['ST101-panel']);
      expect(users.single.roleName, 'Panel Operator');
      expect(users.single.stationAccount, isTrue);
    });

    test('arm 3: the audit trail reads through auditTrailStoreProvider',
        () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final store = await container.read(auditTrailStoreProvider.future);
      expect(store, isNotNull);
      final rows = await store!.entries(AuditQuery());
      expect(rows, hasLength(1));
      expect(rows.single.who, 'ST101-panel');
      expect(rows.single.itemKey, 'ST101.CN01.MOT01');
      expect(rows.single.origin, 'relay');
      expect(await store.distinctWho(), ['ST101-panel']);
      expect(await store.memberCountsByAction(['A-17-12']), {'A-17-12': 3});
    });

    test('arm 4: the audit sink is NOT NullAuditSink in gateway mode',
        () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isNot(isA<NullAuditSink>()),
          reason: 'criterion 3\'s literal claim: an audit trail that quietly '
              'stops recording when the transport changes is worse than no '
              'audit trail, because it looks like one. NullAuditSink covers '
              'two real cases — the boot window and a station commissioned '
              'without Postgres — and gateway mode is a third that must not '
              'fall into it silently');
      expect(sink, isNot(isA<DriftAuditSink>()),
          reason: 'there is no database to drift into');
      // A record through the gateway-mode sink must complete — the relayed
      // operations themselves are audited server-side by the policy
      // decorator (D-05), and a sink that hung a caller would stall the
      // plant write it was recording.
      await sink
          .record(AuditRecord.login(
            who: 'jon',
            station: 'phase17-panel',
            roleName: 'Engineering',
            actionId: 'A-arm4',
          ))
          .timeout(const Duration(seconds: 1));
    });

    test('arm 4 anti-vacuity: DIRECT mode with no database is still '
        'NullAuditSink — the two real cases are unchanged', () async {
      final container = _directContainer(database: () async => null);
      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isA<NullAuditSink>(),
          reason: 'the boot window and a station commissioned without '
              'Postgres keep the null sink; the doc names them and this arm '
              'keeps the claim honest');
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 5: gateway mode, databaseProvider THROWS
  // ---------------------------------------------------------------------------

  group('gateway mode with the database THROWING', () {
    test('arm 5: all four providers still answer — a provider can be '
        'null-safe and still propagate an exception from a watch it did not '
        'need', () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: _throwingDatabase);

      final templates =
          await container.read(accessTemplateStoreProvider.future);
      expect(templates, isNotNull);
      expect((await templates!.list()).map((t) => t.name), ['conveyor-1']);

      final admin = await container.read(accessAdminStoreProvider.future);
      expect(admin, isNotNull);
      expect((await admin!.roles()).map((r) => r.name), ['Panel Operator']);

      final audit = await container.read(auditTrailStoreProvider.future);
      expect(audit, isNotNull);
      expect(await audit!.distinctWho(), ['ST101-panel']);

      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isNot(isA<NullAuditSink>()));
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 6: direct mode is untouched
  // ---------------------------------------------------------------------------

  group('direct mode with a database', () {
    test('arm 6: all four providers answer exactly the concrete types they '
        'answer today', () async {
      final db = _testDatabase();
      final container = _directContainer(database: () async => db);

      final templates =
          await container.read(accessTemplateStoreProvider.future);
      expect(templates.runtimeType, AccessTemplateStore,
          reason: 'direct mode must not change: same provider, same store, '
              'same rows — the phase adds a route, it does not replace one');

      final admin = await container.read(accessAdminStoreProvider.future);
      expect(admin.runtimeType, AccessAdminStore);

      final audit = await container.read(auditTrailStoreProvider.future);
      expect(audit.runtimeType, AuditTrailStore);

      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isA<DriftAuditSink>());
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 7: a gateway refusal is AccessDenied — one arm per store
  // ---------------------------------------------------------------------------

  group('a gateway refusal is the same AccessDenied a direct refusal is', () {
    Map<String, _Answer> refusals() => {
          ..._servedFamilies(),
          AccessMethods.templateCreate: (link, id) => link.error(
              id,
              _forbidden,
              'accessTemplates.create: the session lacks users; the call '
              '$_refusalWording'),
          AccessMethods.adminCreateRole: (link, id) => link.error(
              id,
              _forbidden,
              'accessAdmin.createRole: the session lacks users; the call '
              '$_refusalWording'),
          AccessMethods.auditEntries: (link, id) => link.error(
              id,
              _forbidden,
              'audit.entries: the session lacks users; the call '
              '$_refusalWording'),
        };

    test('arm 7a: templates — create refused', () async {
      final gateway = await _gateway(refusals());
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final store =
          (await container.read(accessTemplateStoreProvider.future))!;

      Object? caught;
      try {
        await store.create(_servedTemplate);
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<AccessDenied>(),
          reason: 'one exception type, so no screen can tell which transport '
              'refused it (D-09)');
      expect('$caught', contains(_refusalWording),
          reason: 'the gateway\'s sentence — the call had no effect, do not '
              'retry — must survive to the operator');
    });

    test('arm 7b: admin — createRole refused', () async {
      final gateway = await _gateway(refusals());
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final store =
          (await container.read(accessAdminStoreProvider.future))!;

      Object? caught;
      try {
        await store.createRole(_servedRole);
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<AccessDenied>());
      expect('$caught', contains(_refusalWording));
    });

    test('arm 7c: audit — a refused read is AccessDenied too', () async {
      final gateway = await _gateway(refusals());
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final store = (await container.read(auditTrailStoreProvider.future))!;

      Object? caught;
      try {
        await store.entries(AuditQuery());
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<AccessDenied>());
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 8: a domain error keeps its type
  // ---------------------------------------------------------------------------

  group('a domain error keeps its type across the wire', () {
    test('arm 8: a template_in_use payload becomes TemplateInUseException '
        'carrying the name and the bound keys', () async {
      final gateway = await _gateway({
        ..._servedFamilies(),
        AccessMethods.templateDelete: (link, id) => _errorWithData(
            link,
            id,
            _handlerFailed,
            'accessTemplates.delete failed: "conveyor-1" is bound',
            {
              'code': 'template_in_use',
              'templateName': 'conveyor-1',
              'boundKeys': ['ST101.CN01.MOT01', 'ST201.CN04.MOT01'],
            }),
      });
      final container =
          await _gatewayPanel(gateway, database: () async => null);
      final store =
          (await container.read(accessTemplateStoreProvider.future))!;

      Object? caught;
      try {
        await store.delete('conveyor-1');
      } on Object catch (error) {
        caught = error;
      }
      expect(caught, isA<TemplateInUseException>(),
          reason: 'not a string, not a generic error: a screen that says '
              '"failed" where it could say "still bound to 2 keys" is a '
              'regression from direct mode');
      final domain = caught! as TemplateInUseException;
      expect(domain.templateName, 'conveyor-1');
      expect(domain.boundKeys, ['ST101.CN01.MOT01', 'ST201.CN04.MOT01']);
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 9: the transport can be swapped underneath
  // ---------------------------------------------------------------------------

  group('the transport swapped underneath', () {
    test('arm 9: invalidating stateManProvider rebuilds the stores onto the '
        'new client — alarm.dart:45\'s defect, armed', () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      // The stores work on the first client.
      final before =
          (await container.read(accessTemplateStoreProvider.future))!;
      expect((await before.list()).map((t) => t.name), ['conveyor-1']);
      expect(
          (await container.read(accessAdminStoreProvider.future))!,
          isNotNull);
      final dialsBefore = gateway.accepted;

      // What every key_mappings save does in gateway mode:
      // `GatewayStateMan.updateKeyMappings` reports a reload unconditionally
      // and `stateManProvider` invalidates itself, DISPOSING the
      // RemoteStateMan underneath. With `ref.read` the store providers were
      // never invalidated and kept proxies over a dead client — and because
      // that client CLOSES its streams rather than erroring them, nothing
      // reported it (the Phase 14 blocker, `alarm.dart:45`).
      container.invalidate(stateManProvider);

      final templates =
          (await container.read(accessTemplateStoreProvider.future))!;
      expect((await templates.list()).map((t) => t.name), ['conveyor-1'],
          reason: 'the store must answer through the NEW client; a cached '
              'store over the disposed one either throws or hangs');

      final admin =
          (await container.read(accessAdminStoreProvider.future))!;
      expect((await admin.roles()).map((r) => r.name), ['Panel Operator']);

      final audit = (await container.read(auditTrailStoreProvider.future))!;
      expect(await audit.distinctWho(), ['ST101-panel']);

      expect(gateway.accepted, greaterThan(dialsBefore),
          reason: 'the far end must have seen a second socket — the proof '
              'the calls above were served by the rebuilt client rather '
              'than a survivor of the old one');
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 11: gateway mode WITH a database — T-17-12b's other half
  // ---------------------------------------------------------------------------

  group('gateway mode WITH a database', () {
    test('arm 11: the relayed route is still taken when Postgres is '
        'reachable — a route that exists will be taken, so it must not exist',
        () async {
      final gateway = await _gateway(_servedFamilies());
      final db = _testDatabase();
      final container = await _gatewayPanel(gateway, database: () async => db);

      final templates =
          (await container.read(accessTemplateStoreProvider.future))!;
      expect(templates.runtimeType, isNot(AccessTemplateStore),
          reason: 'a gateway branch that falls through to the local path '
              'when a database happens to be present is the panel silently '
              'bypassing the server-side gate (T-17-12b) — arms 1-4 cannot '
              'see it because they override the database away');
      expect((await templates.list()).map((t) => t.name), ['conveyor-1'],
          reason: 'the answer must be the gateway\'s; the local database '
              'has no templates at all');

      final admin = (await container.read(accessAdminStoreProvider.future))!;
      expect(admin.runtimeType, isNot(AccessAdminStore));
      expect((await admin.roles()).map((r) => r.name), ['Panel Operator']);

      final audit = (await container.read(auditTrailStoreProvider.future))!;
      expect(audit.runtimeType, isNot(AuditTrailStore));
      expect(await audit.distinctWho(), ['ST101-panel']);

      final sink = await container.read(auditSinkProvider.future);
      expect(sink, isNot(isA<DriftAuditSink>()),
          reason: 'panel-side rows beside the server\'s rows would split '
              'the one trail in two for every relayed action');
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 10: the local auth path is gone in gateway mode — sign-in is the
  // relay's now
  // ---------------------------------------------------------------------------
  //
  // This arm used to pin "sign-in reads unavailable" as the correct end state,
  // and that WAS the PRIMARY defect: 17-12 relayed the access stores and left
  // authentication on a Postgres connection the gateway panel no longer has,
  // so nobody could ever sign in. Increment B routes sign-in over the socket
  // (`AccessSessionController._signInOverRelay`), verified server-side. What
  // stays true here is the two facts this arm was really about: there is no
  // LOCAL auth path on a gateway panel (authProvider null, no database), and
  // an unelevated station sits at the seeded Operator floor. The sign-in
  // path's own behaviour — ok / bad_credentials / unavailable, and no
  // persisted session — is `gateway_signin_test.dart`, which drives the relay
  // seam directly rather than standing up a scripted gateway per outcome.

  group('gateway mode has no LOCAL auth path — sign-in moved to the relay',
      () {
    test('arm 10: authProvider null and the station is the Operator floor '
        'until a relay sign-in elevates it', () async {
      final gateway = await _gateway(_servedFamilies());
      final container =
          await _gatewayPanel(gateway, database: () async => null);

      expect(await container.read(authProviderProvider.future), isNull,
          reason: 'a gateway panel holds no database, so the LOCAL auth '
              'provider is null — authentication is the gateway\'s job now, '
              'reached through RemoteStateMan.sessionLogin');

      final session = await container.read(accessSessionProvider.future);
      expect(session.isElevated, isFalse);
      expect(
          session.groups,
          kSeedRoles.firstWhere((r) => r.name == kOperatorRoleName).groups,
          reason: 'an unelevated station is an Operator — the seeded floor, '
              'not a guess (access.dart)');
    });
  });
}

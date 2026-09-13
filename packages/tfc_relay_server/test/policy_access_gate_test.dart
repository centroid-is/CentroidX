@TestOn('vm')

/// The four access families get their gate — and the two rulings that came in
/// with it (2026-09-08, audit-mandated, owner-known):
///
/// **FIX 1 — the trail and the account list are gated behind `users`,
/// server-side.** The app's "no read gate" deferral was reasoned for a panel
/// already holding Postgres credentials: a reader who can open the database
/// gains nothing from a UI gate. Over the wire that premise is false — a
/// valid token is NOT database credentials, and an ungated `audit.entries` /
/// `accessAdmin.listUsers` would let any station, view-only included,
/// enumerate every username, every role and the whole audit trail. The group
/// asked is the master's own answer for the roles-users-trail concern
/// (`AccessPolicy.groupForAdmin` → `users`; `AccessSurface.accessAdmin`'s doc:
/// "they all answer to `users`") — the master's rule asked at the wire, not a
/// second rule.
///
/// Every refusal arm here has a **live control** — a `users`-holding session
/// that is answered, with the fake recording that it was consulted — because
/// a fixture that also refuses proves nothing (today's finding, and D-12's).
///
/// **FIX 2 — a `forbidden` never echoes a secret** (F-B/F-G, 17-03/17-05).
/// Over the channel the client re-raises clean, so a server-side echo is
/// invisible to client-side checks; the pin has to live on the server. The
/// arms drive `setUserPassword` and `createUser` refusals with a distinctive
/// password and assert it appears nowhere in the thrown message and in no
/// field of any audit row.
@Tags(['ws'])
library;

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';
import 'package:tfc_relay_server/src/error_codes.dart';
import 'package:tfc_relay_server/src/policy/key_policy.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/policy/series_mapping_tally.dart';
import 'package:tfc_stateman_contract/testing/fake_state_man.dart';

import 'support/permissive_resolver.dart';
import 'support/scripted_policy.dart';

/// The distinctive secret FIX 2 drives through the refusal path. Never a
/// plausible password: if this string shows up anywhere, it can only have
/// come from the params object.
const _secret = 'ÞYRNIGERÐI-9000-lykilorð';

/// Holds every group EXCEPT `users` — the strongest wrong-group session: even
/// `administer` must not open the account list or the trail.
final _everythingButUsers = stationHolding(
    AccessGroup.values.where((group) => group != AccessGroup.users).toSet(),
    station: 'ST101',
    username: 'ST101-panel',
    roleName: 'Line Panel');

/// Holds `users` — the live control.
final _userAdmin = stationHolding(const {AccessGroup.users},
    station: 'HQ-01', username: 'hq-admin-panel', roleName: 'User Admin');

/// Holds `administer` — for the backendConfig family.
final _administrator = stationHolding(const {AccessGroup.administer});

// ---------------------------------------------------------------------------
// The fakes: every member records that it was reached, which is what makes a
// live control a control. FakeStateMan's own four getters refuse by name
// (17-03b), so the plant is subclassed to serve these instead.
// ---------------------------------------------------------------------------

final class _FakeAccessAdmin implements AccessAdminApi {
  final reached = <String>[];

  @override
  Future<List<AccessRole>> roles() async {
    reached.add('roles');
    return const [AccessRole(name: 'Line Panel', groups: {})];
  }

  @override
  Future<List<UserSummary>> listUsers() async {
    reached.add('listUsers');
    return const [
      UserSummary(
          username: 'jon', roleName: 'User Admin', stationAccount: false),
    ];
  }

  @override
  Future<void> createRole(AccessRole role, {String? reason}) async =>
      reached.add('createRole');

  @override
  Future<void> updateRole(AccessRole role, {String? reason}) async =>
      reached.add('updateRole');

  @override
  Future<void> deleteRole(String name, {String? reason}) async =>
      reached.add('deleteRole');

  @override
  Future<void> renameRole(String from, String to, {String? reason}) async =>
      reached.add('renameRole');

  @override
  Future<void> createUser(NewUserParams params) async =>
      reached.add('createUser');

  @override
  Future<void> deleteUser(String subject, {String? reason}) async =>
      reached.add('deleteUser');

  @override
  Future<void> setUserRole(String subject, String newRole,
          {String? reason}) async =>
      reached.add('setUserRole');

  @override
  Future<void> setUserStationAccount(String subject, bool value,
          {String? reason}) async =>
      reached.add('setUserStationAccount');

  @override
  Future<void> setRolePages(String subject, Set<String>? pages,
          {String? reason}) async =>
      reached.add('setRolePages');

  @override
  Future<void> setUserPages(String subject, Set<String>? pages,
          {String? reason}) async =>
      reached.add('setUserPages');

  @override
  Future<void> setUserPassword(SetUserPasswordParams params) async =>
      reached.add('setUserPassword');
}

final class _FakeAudit implements AuditApi {
  final reached = <String>[];

  @override
  Future<List<AuditRecord>> entries(AuditQueryParams query) async {
    reached.add('entries');
    return const [];
  }

  @override
  Future<Map<String, int>> memberCountsByAction(List<String> actionIds) async {
    reached.add('memberCountsByAction');
    return const {};
  }

  @override
  Future<List<String>> distinctWho() async {
    reached.add('distinctWho');
    return const ['jon'];
  }
}

final class _FakeTemplates implements AccessTemplateApi {
  final reached = <String>[];

  @override
  Future<List<AccessTemplate>> list() async {
    reached.add('list');
    return const [];
  }

  @override
  Future<Map<String, String>> bindings() async {
    reached.add('bindings');
    return const {};
  }

  @override
  Future<List<String>> keysBoundTo(String templateName) async {
    reached.add('keysBoundTo');
    return const [];
  }

  @override
  Future<void> create(AccessTemplate value, {String? reason}) async =>
      reached.add('create');

  @override
  Future<void> update(AccessTemplate value, {String? reason}) async =>
      reached.add('update');

  @override
  Future<void> rename(String from, String to, {String? reason}) async =>
      reached.add('rename');

  @override
  Future<void> delete(String name, {String? reason}) async =>
      reached.add('delete');

  @override
  Future<void> bind(String keyName, String templateName,
          {String? reason}) async =>
      reached.add('bind');

  @override
  Future<void> unbind(String keyName, {String? reason}) async =>
      reached.add('unbind');
}

final class _FakeBackendConfig implements BackendConfigApi {
  final reached = <String>[];

  @override
  Future<BackendConfigDocument> read() async {
    reached.add('read');
    return const BackendConfigDocument(configJson: '{}');
  }

  @override
  Future<ConfigValidation> validate(String configJson) async {
    reached.add('validate');
    return const ConfigValidation(ok: true);
  }

  @override
  Future<void> write(String configJson, {String? reason}) async =>
      reached.add('write');

  @override
  Future<BackendConfigDocument?> previous() async {
    reached.add('previous');
    return null;
  }

  @override
  Future<void> restorePrevious({String? reason}) async =>
      reached.add('restorePrevious');
}

/// A plant whose four access families are the recording fakes above.
final class _AccessBackedPlant extends FakeStateMan {
  _AccessBackedPlant();

  final admin = _FakeAccessAdmin();
  final trail = _FakeAudit();
  final templates = _FakeTemplates();
  final config = _FakeBackendConfig();

  @override
  AccessAdminApi get accessAdmin => admin;

  @override
  AuditApi get audit => trail;

  @override
  AccessTemplateApi get accessTemplates => templates;

  @override
  BackendConfigApi get backendConfig => config;
}

final class _RecordingSink implements AuditSink {
  final rows = <AuditRecord>[];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

({_AccessBackedPlant plant, _RecordingSink sink, PolicyStateMan served})
    _seenBy(StationIdentity? identity) {
  final plant = _AccessBackedPlant();
  addTearDown(plant.dispose);
  final sink = _RecordingSink();
  return (
    plant: plant,
    sink: sink,
    served: PolicyStateMan(
      source: plant,
      policy: const AccessPolicyKeyPolicy(),
      resolver: const PermissiveSeriesResolver(),
      tally: SeriesMappingTally(),
      identityOf: () => identity,
      sink: sink,
    ),
  );
}

/// Runs [call] expecting a refusal, and hands the refusal back.
Future<rpc.RpcException> _refused(
    Future<void> Function() call, String what) async {
  try {
    await call();
  } on rpc.RpcException catch (error) {
    return error;
  }
  fail('$what was answered instead of refused');
}

/// Every string field of [row], for the no-secret sweep.
List<String?> _stringsOf(AuditRecord row) => [
      row.who,
      row.station,
      row.roleName,
      row.surface,
      row.itemKey,
      row.member,
      row.oldValue,
      row.newValue,
      row.groupRequired,
      row.origin,
      row.actionId,
      row.reason,
    ];

void main() {
  group('FIX 1: the trail and the account list take users, server-side', () {
    for (final probe in <String,
        Future<void> Function(PolicyStateMan served)>{
      'audit.entries': (served) =>
          served.audit.entries(const AuditQueryParams()),
      'audit.memberCountsByAction': (served) =>
          served.audit.memberCountsByAction(const ['deadbeef']),
      'audit.distinctWho': (served) => served.audit.distinctWho(),
      'accessAdmin.listUsers': (served) => served.accessAdmin.listUsers(),
    }.entries) {
      test('${probe.key} is refused for a session holding everything but '
          'users — and the source is never consulted', () async {
        final seat = _seenBy(_everythingButUsers);

        final refusal = await _refused(() => probe.value(seat.served),
            '${probe.key} from a session without users');

        expect(refusal.code, ServerErrorCodes.forbidden,
            reason: 'over the wire a valid token is not database '
                'credentials: without this gate any station could enumerate '
                'every username, every role and the whole trail. Even '
                'administer must not open it — users is the one group that '
                'answers for who-may-do-what');
        expect(seat.plant.admin.reached, isEmpty,
            reason: 'the refusal must be raised before the thunk is '
                'evaluated: a refused caller may not cost a lookup, and on '
                'an unwired source the lookup would be an UnsupportedError '
                'masquerading as the verdict');
        expect(seat.plant.trail.reached, isEmpty);

        expect(seat.sink.rows, hasLength(1),
            reason: 'a refusal is a verdict, and a verdict writes a row '
                '(D-05) — a station probing the account list is exactly the '
                'event the trail exists to show');
        expect(seat.sink.rows.single.allowed, isFalse);
        expect(seat.sink.rows.single.groupRequired, 'users');
      });
    }

    test('a users-holding session is answered — the live control, with the '
        'fake recording the consultation', () async {
      final seat = _seenBy(_userAdmin);

      expect(await seat.served.audit.entries(const AuditQueryParams()),
          isEmpty);
      expect(await seat.served.audit.distinctWho(), ['jon']);
      expect(
          await seat.served.audit.memberCountsByAction(const ['deadbeef']),
          isEmpty);
      final users = await seat.served.accessAdmin.listUsers();
      expect(users.single.username, 'jon',
          reason: 'the same call one group later goes through and answers '
              'real data — a fixture that also refuses proves nothing');

      expect(seat.plant.trail.reached,
          ['entries', 'distinctWho', 'memberCountsByAction'],
          reason: 'the source really was consulted, in order, once each');
      expect(seat.plant.admin.reached, ['listUsers']);

      expect(seat.sink.rows, isEmpty,
          reason: 'an ALLOWED read of the trail records nothing — reading '
              'the trail must not grow the trail, which is '
              'audit_trail_store.dart\'s own refusal-by-design');
    });

    test('roles() stays an open read, matching the store', () async {
      // The fence around FIX 1: the ruling names audit.* and listUsers, and
      // widening it silently would be this file deciding policy. A role's
      // name and group set is what the templates screen renders.
      final seat = _seenBy(_everythingButUsers);
      expect((await seat.served.accessAdmin.roles()).single.name,
          'Line Panel');
      expect(seat.plant.admin.reached, ['roles']);
    });
  });

  group('FIX 2: a forbidden never echoes a secret', () {
    test('a refused setUserPassword carries the subject and never the '
        'password — message and every row field', () async {
      final seat = _seenBy(_everythingButUsers);

      final refusal = await _refused(
          () => seat.served.accessAdmin.setUserPassword(
              const SetUserPasswordParams(subject: 'jon', password: _secret)),
          'a password reset from a session without users');

      expect(refusal.code, ServerErrorCodes.forbidden);
      expect(refusal.message, isNot(contains(_secret)),
          reason: 'the client re-raises the message clean over the channel, '
              'so a server-side echo is invisible to client-side checks — '
              'this pin is the server-side one, and it is the only place it '
              'can live');
      expect('${refusal.data}', isNot(contains(_secret)),
          reason: 'the data map travels in the same frame; a pre-substituted '
              'request is the 02-05 rule AND the no-echo rule at once');
      expect(refusal.message, contains('jon'),
          reason: 'the subject is not a secret, and a refusal that names '
              'nobody is one an operator cannot act on');

      expect(seat.sink.rows, hasLength(1));
      for (final field in _stringsOf(seat.sink.rows.single)) {
        expect(field, isNot(contains(_secret)),
            reason: 'the deny row outlives the frame — log files travel '
                'further than the database does, and a trail that leaks '
                'credentials is worse than no trail');
      }
      expect(seat.plant.admin.reached, isEmpty,
          reason: 'pre-effect: the store never saw the reset');
    });

    test('a refused createUser carries the subject and never the password',
        () async {
      final seat = _seenBy(_everythingButUsers);

      final refusal = await _refused(
          () => seat.served.accessAdmin.createUser(const NewUserParams(
              subject: 'nyr-adgangur',
              password: _secret,
              grantedRole: 'Line Panel')),
          'an account creation from a session without users');

      expect(refusal.message, isNot(contains(_secret)),
          reason: 'F-B: createUser carries a secret too — the plan that said '
              'setUserPassword was the only one was wrong once already');
      expect('${refusal.data}', isNot(contains(_secret)));
      for (final field in _stringsOf(seat.sink.rows.single)) {
        expect(field, isNot(contains(_secret)));
      }
      expect(seat.plant.admin.reached, isEmpty);
    });

    test('the live control: a users-holding session resets and creates, and '
        'the allow rows carry no password either', () async {
      final seat = _seenBy(_userAdmin);

      await seat.served.accessAdmin.setUserPassword(
          const SetUserPasswordParams(subject: 'jon', password: _secret));
      await seat.served.accessAdmin.createUser(const NewUserParams(
          subject: 'nyr-adgangur',
          password: _secret,
          grantedRole: 'Line Panel'));

      expect(seat.plant.admin.reached, ['setUserPassword', 'createUser'],
          reason: 'the same two calls one group later reach the store');
      expect(seat.sink.rows, hasLength(2),
          reason: 'allowed admin writes are decisions too, and each writes '
              'its row');
      for (final row in seat.sink.rows) {
        expect(row.allowed, isTrue);
        for (final field in _stringsOf(row)) {
          expect(field, isNot(contains(_secret)),
              reason: 'the allow row is the easier one to get wrong — it is '
                  'built on the path that HAS the params object in hand');
        }
      }
    });
  });

  group('the other write gates, each with its live control', () {
    test('an admin write is refused without users and reaches the store with '
        'it', () async {
      final refused = _seenBy(_everythingButUsers);
      await _refused(
          () => refused.served.accessAdmin.setUserRole('jon', 'Wall'),
          'a role move from a session without users');
      expect(refused.plant.admin.reached, isEmpty);
      expect(refused.sink.rows.single.allowed, isFalse);

      final allowed = _seenBy(_userAdmin);
      await allowed.served.accessAdmin.setUserRole('jon', 'Wall');
      expect(allowed.plant.admin.reached, ['setUserRole']);
      expect(allowed.sink.rows.single.allowed, isTrue);
    });

    test('a template write is refused without users and reaches the store '
        'with it — and the template reads stay open', () async {
      final refused = _seenBy(_everythingButUsers);
      await _refused(
          () => refused.served.accessTemplates
              .bind('CN01.MOT01.speed', 'Drives'),
          'a binding from a session without users');
      expect(refused.plant.templates.reached, isEmpty,
          reason: 'a binding changes who may write the key just as much as a '
              'template edit does');

      expect(await refused.served.accessTemplates.list(), isEmpty,
          reason: 'the reads stay open, matching the store: a panel renders '
              'the templates screen before anyone signs in');
      expect(refused.plant.templates.reached, ['list']);

      final allowed = _seenBy(_userAdmin);
      await allowed.served.accessTemplates.bind('CN01.MOT01.speed', 'Drives');
      expect(allowed.plant.templates.reached, ['bind']);
    });

    test('every backendConfig member takes administer — read included, '
        'because the document is the plant\'s addresses', () async {
      final refused = _seenBy(_userAdmin); // users, deliberately: not enough
      await _refused(() => refused.served.backendConfig.read(),
          'a config read from a session without administer');
      await _refused(() => refused.served.backendConfig.write('{}'),
          'a config write from a session without administer');
      expect(refused.plant.config.reached, isEmpty);

      final allowed = _seenBy(_administrator);
      expect((await allowed.served.backendConfig.read()).configJson, '{}');
      await allowed.served.backendConfig.write('{}');
      expect(allowed.plant.config.reached, ['read', 'write']);
      expect(
          allowed.sink.rows.map((row) => row.allowed).toList(), [true],
          reason: 'the write records its allow row; the read, like every '
              'read, records nothing');
    });
  });
}

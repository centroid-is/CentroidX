/// The backend's three access families, judged over the real stores.
///
/// 17-06's in-memory leg: `BackendAccessTemplates`, `BackendAccessAdmin` and
/// `BackendAudit` over an in-memory `AppDatabase`, delegating every decision to
/// the store that owns it. The claims, one arm each:
///
///  1. delegation is real — a backend write is readable through the layer below
///  2. the gate is the store's and still fires: fifteen refusals from a table,
///     each with an anti-vacuity half and a pre-effect half
///  3. the deny row is written, and before the throw
///  4. `origin` is `'relay'` on this path and `'operator'` on the app's
///  5. attribution: who / station / roleName land in the row
///  6. composed without a database, every member refuses BY NAME (P-12)
///  7. reads are ungated — read permissions are deferred, spec §11
///  8. the last-`users`-holder invariant survives the trip
///  9. domain exceptions cross intact
/// 10. this layer holds no permission check of its own (the grep)
///
/// ## Why the fixture is `AppDatabase.inMemoryForTest()`
///
/// The plan pointed at `backend_data_services_test.dart`'s fixture; that file
/// fakes its sources in memory and holds no `AppDatabase` at all. The real
/// fixture is `test/core/access/store_move_test.dart`'s — the stores over an
/// in-memory drift database with the seeded schema — and it is reused here in
/// shape rather than duplicated in spirit.
///
/// ## `accessTemplates.template` is cut from the wire
///
/// A live 17-06 correction: the wire loses `template(name)`; a remote needing
/// one template derives it from `list()`. The member is therefore NOT
/// delegated to the store — it refuses by name, database or no database — and
/// it has its own arm rather than a row in the members table.
library;

import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm, OrderingMode;
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/access_template_store.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database_drift.dart';
import 'package:tfc_dart/core/relay/backend_access.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart' as relay;

/// The page editor who must not be able to decide who may do what. The
/// highest-held group is `configure`, so a gate lowered to `configure` — the
/// exact mistake the store docs war-game — is caught by these arms.
const AccessSession _configureOnly = AccessSession(
  user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
  groups: {
    AccessGroup.operate,
    AccessGroup.setpoints,
    AccessGroup.device,
    AccessGroup.configure,
  },
);

/// The station account a relay session resolves to (D-11's shape: a panel,
/// not a person). Holds `users` so the permitted halves exercise the writes.
const AccessSession _stationWithUsers = AccessSession(
  user: AuthenticatedUser(
    username: 'ST101-panel',
    roleName: 'Panel Admin',
    stationAccount: true,
  ),
  groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
);

/// Nobody signed in, nothing held — the session arm 7 drives the reads with.
const AccessSession _holdingNothing = AccessSession(groups: {});

AccessTemplate _template(String name,
        {Map<String, AccessGroup> rules =
            const {'CN01.*': AccessGroup.setpoints}}) =>
    AccessTemplate(name: name, rules: rules);

void main() {
  late AppDatabase db;
  late AccessSession session;
  late List<AccessDenied> denials;
  late BackendAccessTemplates templates;
  late BackendAccessAdmin admin;
  late BackendAudit audit;

  setUp(() async {
    // PBKDF2 at production iteration counts costs the better part of a second
    // per account, and the user arms create several.
    Pbkdf2Kdf.iterationsForTest = 10;
    db = AppDatabase.inMemoryForTest();
    // Force the schema — and the seeded roles — to exist before the first
    // store call.
    await db.customSelect('SELECT 1').getSingle();
    denials = [];
    session = _stationWithUsers;
    templates = BackendAccessTemplates(
      database: db,
      session: () => session,
      station: 'ST101',
      audit: DriftAuditSink(db),
      onDenied: denials.add,
    );
    admin = BackendAccessAdmin(
      database: db,
      session: () => session,
      station: 'ST101',
      audit: DriftAuditSink(db),
      onDenied: denials.add,
    );
    audit = BackendAudit(database: db);
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  Future<int> countOf(String table) async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle();
    return row.read<int>('c');
  }

  /// The whole target table as one comparable string, so "the refusal had no
  /// effect" is checkable for updates and renames too, where a row COUNT is
  /// unchanged by success and the pre-effect half would otherwise be vacuous.
  Future<String> dumpOf(String table) async {
    final rows =
        await db.customSelect('SELECT * FROM $table ORDER BY 1').get();
    return rows.map((r) => r.data.toString()).join('\n');
  }

  Future<AuditEntryData> lastAuditRow() =>
      (db.select(db.auditEntry)
            ..orderBy([
              (t) => OrderingTerm(
                  expression: t.id, mode: OrderingMode.desc),
            ])
            ..limit(1))
          .getSingle();

  // The fifteen writes, driven from a table so a member added later without an
  // arm is visible: 6 template writes + 9 admin writes. `prepare` runs as the
  // `users` station and seeds each write's preconditions through the backend
  // itself; `act` is the call under judgement; `table` is where the effect
  // lands; `deniedItemKey` is the member vocabulary the deny row must carry.
  final writes = <({
    String name,
    String table,
    String deniedItemKey,
    Future<void> Function() Function() prepare,
    Future<void> Function() Function() act,
  })>[
    (
      name: 'templates.create',
      table: 'access_template',
      deniedItemKey: 'access_template.T_c',
      prepare: () => () async {},
      act: () => () => templates.create(_template('T_c')),
    ),
    (
      name: 'templates.update',
      table: 'access_template',
      deniedItemKey: 'access_template.T_u',
      prepare: () => () => templates.create(_template('T_u')),
      act: () => () => templates.update(
          _template('T_u', rules: const {'CN02.*': AccessGroup.device})),
    ),
    (
      name: 'templates.rename',
      table: 'access_template',
      deniedItemKey: 'access_template.T_r',
      prepare: () => () => templates.create(_template('T_r')),
      act: () => () => templates.rename('T_r', 'T_r2'),
    ),
    (
      name: 'templates.delete',
      table: 'access_template',
      deniedItemKey: 'access_template.T_d',
      prepare: () => () => templates.create(_template('T_d')),
      act: () => () => templates.delete('T_d'),
    ),
    (
      name: 'templates.bind',
      table: 'access_key_binding',
      deniedItemKey: 'access_key_binding.k.bound',
      prepare: () => () => templates.create(_template('T_b')),
      act: () => () => templates.bind('k.bound', 'T_b'),
    ),
    (
      name: 'templates.unbind',
      table: 'access_key_binding',
      deniedItemKey: 'access_key_binding.k.unbound',
      prepare: () => () async {
        await templates.create(_template('T_ub'));
        await templates.bind('k.unbound', 'T_ub');
      },
      act: () => () => templates.unbind('k.unbound'),
    ),
    (
      name: 'admin.createRole',
      table: 'app_role',
      deniedItemKey: 'role.create',
      prepare: () => () async {},
      act: () => () => admin.createRole(
          const AccessRole(name: 'R_c', groups: {AccessGroup.operate})),
    ),
    (
      name: 'admin.updateRole',
      table: 'app_role',
      deniedItemKey: 'role.update',
      prepare: () => () => admin.createRole(
          const AccessRole(name: 'R_u', groups: {AccessGroup.operate})),
      act: () => () => admin.updateRole(const AccessRole(
          name: 'R_u', groups: {AccessGroup.operate, AccessGroup.setpoints})),
    ),
    (
      name: 'admin.renameRole',
      table: 'app_role',
      deniedItemKey: 'role.rename',
      prepare: () => () => admin.createRole(
          const AccessRole(name: 'R_r', groups: {AccessGroup.operate})),
      act: () => () => admin.renameRole('R_r', 'R_r2'),
    ),
    (
      name: 'admin.deleteRole',
      table: 'app_role',
      deniedItemKey: 'role.delete',
      prepare: () => () => admin.createRole(
          const AccessRole(name: 'R_d', groups: {AccessGroup.operate})),
      act: () => () => admin.deleteRole('R_d'),
    ),
    (
      name: 'admin.createUser',
      table: 'app_user',
      deniedItemKey: 'user.create',
      prepare: () => () => admin.createRole(
          const AccessRole(name: 'R_uc', groups: {AccessGroup.operate})),
      act: () => () => admin.createUser(const relay.NewUserParams(
          subject: 'u_c',
          password: 'a sufficiently long pw',
          grantedRole: 'R_uc')),
    ),
    (
      name: 'admin.deleteUser',
      table: 'app_user',
      deniedItemKey: 'user.delete',
      prepare: () => () async {
        await admin.createRole(
            const AccessRole(name: 'R_du', groups: {AccessGroup.operate}));
        await admin.createUser(const relay.NewUserParams(
            subject: 'u_d',
            password: 'a sufficiently long pw',
            grantedRole: 'R_du'));
      },
      act: () => () => admin.deleteUser('u_d'),
    ),
    (
      name: 'admin.setUserRole',
      table: 'app_user',
      deniedItemKey: 'user.role',
      prepare: () => () async {
        await admin.createRole(
            const AccessRole(name: 'R_a', groups: {AccessGroup.operate}));
        await admin.createRole(
            const AccessRole(name: 'R_b', groups: {AccessGroup.operate}));
        await admin.createUser(const relay.NewUserParams(
            subject: 'u_sr',
            password: 'a sufficiently long pw',
            grantedRole: 'R_a'));
      },
      act: () => () => admin.setUserRole('u_sr', 'R_b'),
    ),
    (
      name: 'admin.setUserStationAccount',
      table: 'app_user',
      deniedItemKey: 'user.station_account',
      prepare: () => () async {
        await admin.createRole(
            const AccessRole(name: 'R_sa', groups: {AccessGroup.operate}));
        await admin.createUser(const relay.NewUserParams(
            subject: 'u_sa',
            password: 'a sufficiently long pw',
            grantedRole: 'R_sa'));
      },
      act: () => () => admin.setUserStationAccount('u_sa', true),
    ),
    (
      name: 'admin.setUserPassword',
      table: 'app_user',
      deniedItemKey: 'user.password',
      prepare: () => () async {
        await admin.createRole(
            const AccessRole(name: 'R_sp', groups: {AccessGroup.operate}));
        await admin.createUser(const relay.NewUserParams(
            subject: 'u_sp',
            password: 'a sufficiently long pw',
            grantedRole: 'R_sp'));
      },
      act: () => () => admin.setUserPassword(const relay.SetUserPasswordParams(
          subject: 'u_sp', password: 'another long enough pw')),
    ),
  ];

  // ---------------------------------------------------------------------------
  // Arm 1 — delegation, not re-implementation
  // ---------------------------------------------------------------------------

  group('arm 1: delegation is real', () {
    test('a role created through BackendAccessAdmin is readable through '
        'AccessRepository directly', () async {
      await admin.createRole(const AccessRole(
          name: 'Line Lead',
          groups: {AccessGroup.operate, AccessGroup.setpoints}));

      final row = await AccessRepository(db).role('Line Lead');
      expect(row, isNotNull,
          reason: 'the backend must have written through the same store the '
              'panel writes through, into the same app_role table');
      expect(row!.groups, {AccessGroup.operate, AccessGroup.setpoints});
    });

    test('a template created through BackendAccessTemplates is in '
        'access_template', () async {
      await templates.create(_template('Line 1 setpoints'));

      final row = await db
          .customSelect('SELECT name FROM access_template')
          .getSingle();
      expect(row.read<String>('name'), 'Line 1 setpoints');
    });
  });

  // ---------------------------------------------------------------------------
  // Arms 2 + 3 — the store's gate fires, pre-effect, deny row before the throw
  // ---------------------------------------------------------------------------

  group('arm 2: a configure-only session is refused on every write', () {
    for (final w in writes) {
      test('${w.name} refuses, changes nothing, and the deny row is written '
          'before the throw', () async {
        await w.prepare()();
        final before = await dumpOf(w.table);
        final auditBefore = await countOf('audit_entry');

        session = _configureOnly;
        // Half 1: the refusal itself, and it is the store's AccessDenied.
        await expectLater(w.act()(), throwsA(isA<AccessDenied>()));

        // Half 2: pre-effect — the target table is unchanged, content and all.
        expect(await dumpOf(w.table), before,
            reason: 'a gate that throws after writing refuses just as '
                'visibly; the refusal must precede the effect');

        // Arm 3: exactly one more audit_entry row, allowed = false, carrying
        // the member vocabulary. The count, not just the presence.
        expect(await countOf('audit_entry'), auditBefore + 1,
            reason: 'a refusal that leaves no trace is the one kind of guard '
                'nobody can audit afterwards');
        final deny = await lastAuditRow();
        expect(deny.allowed, isFalse);
        expect(deny.itemKey, w.deniedItemKey);
        expect(deny.groupRequired, AccessGroup.users.name);
      });

      test('${w.name} succeeds for a session holding users (anti-vacuity)',
          () async {
        await w.prepare()();
        final before = await dumpOf(w.table);

        await w.act()();

        expect(await dumpOf(w.table), isNot(before),
            reason: 'the anti-vacuity half: a backend that refused everybody '
                'would pass the refusal arm above and break the plant');
        final allowed = await lastAuditRow();
        expect(allowed.allowed, isTrue);
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Arm 4 — origin
  // ---------------------------------------------------------------------------

  group('arm 4: origin names the transport', () {
    test('a relay-path row carries origin relay; the app path carries '
        'operator — both in one trail', () async {
      // The relay path.
      await admin.createRole(
          const AccessRole(name: 'ViaRelay', groups: {AccessGroup.operate}));
      final relayRow = await lastAuditRow();
      expect(relayRow.origin, 'relay',
          reason: 'D-05: a trail reader must be able to tell a wire write '
              'from a panel write');

      // The app's own construction of the same store — default origin.
      final appStore = AccessAdminStore(
        repository: AccessRepository(db),
        session: () => session,
        audit: DriftAuditSink(db),
        station: 'ST101',
      );
      await appStore.createRole(
          const AccessRole(name: 'ViaPanel', groups: {AccessGroup.operate}));
      final panelRow = await lastAuditRow();
      expect(panelRow.origin, 'operator',
          reason: 'the distinction is a fact, not a convention: the same '
              'store, two construction sites, two origins');
    });

    test('a template-family relay row carries origin relay too', () async {
      await templates.create(_template('OriginCheck'));
      expect((await lastAuditRow()).origin, 'relay');
    });

    test('a deny row on the relay path carries origin relay as well',
        () async {
      session = _configureOnly;
      await expectLater(
        admin.createRole(
            const AccessRole(name: 'Nope', groups: {AccessGroup.operate})),
        throwsA(isA<AccessDenied>()),
      );
      final deny = await lastAuditRow();
      expect(deny.allowed, isFalse);
      expect(deny.origin, 'relay');
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 5 — attribution
  // ---------------------------------------------------------------------------

  test('arm 5: who is the station account, station is the station name, '
      'roleName is the resolved role', () async {
    await templates.create(_template('Attribution'));

    final row = await lastAuditRow();
    expect(row.who, 'ST101-panel',
        reason: 'the token file\'s username, verified server-side (D-11)');
    expect(row.station, 'ST101');
    expect(row.roleName, 'Panel Admin');
  });

  // ---------------------------------------------------------------------------
  // Arm 6 — composed without a database, every member refuses BY NAME
  // ---------------------------------------------------------------------------

  group('arm 6: a null database refuses by name, never an empty answer',
      () {
    late BackendAccessTemplates bareTemplates;
    late BackendAccessAdmin bareAdmin;
    late BackendAudit bareAudit;

    setUp(() {
      bareTemplates = BackendAccessTemplates(
        database: null,
        session: () => session,
        station: 'ST101',
        audit: DriftAuditSink(db),
      );
      bareAdmin = BackendAccessAdmin(
        database: null,
        session: () => session,
        station: 'ST101',
        audit: DriftAuditSink(db),
      );
      bareAudit = BackendAudit(database: null);
    });

    /// Each member's refusal must name the member: "no templates configured"
    /// and "nobody wired a database" must not look the same from a screen
    /// (P-12, backend_alarm_history.dart's _require).
    void expectRefusal(String member, Future<void> Function() call) {
      test('$member refuses, naming itself', () async {
        await expectLater(
          call(),
          throwsA(isA<UnsupportedError>().having(
              (e) => e.message, 'message', contains(member))),
        );
      });
    }

    group('templates', () {
      expectRefusal('BackendAccessTemplates.list', () => bareTemplates.list());
      expectRefusal(
          'BackendAccessTemplates.bindings', () => bareTemplates.bindings());
      expectRefusal('BackendAccessTemplates.keysBoundTo',
          () => bareTemplates.keysBoundTo('T'));
      expectRefusal('BackendAccessTemplates.create',
          () => bareTemplates.create(_template('T')));
      expectRefusal('BackendAccessTemplates.update',
          () => bareTemplates.update(_template('T')));
      expectRefusal('BackendAccessTemplates.rename',
          () => bareTemplates.rename('T', 'T2'));
      expectRefusal(
          'BackendAccessTemplates.delete', () => bareTemplates.delete('T'));
      expectRefusal(
          'BackendAccessTemplates.bind', () => bareTemplates.bind('k', 'T'));
      expectRefusal(
          'BackendAccessTemplates.unbind', () => bareTemplates.unbind('k'));
    });

    group('admin', () {
      expectRefusal('BackendAccessAdmin.roles', () => bareAdmin.roles());
      expectRefusal(
          'BackendAccessAdmin.listUsers', () => bareAdmin.listUsers());
      expectRefusal(
          'BackendAccessAdmin.createRole',
          () => bareAdmin.createRole(
              const AccessRole(name: 'R', groups: {AccessGroup.operate})));
      expectRefusal(
          'BackendAccessAdmin.updateRole',
          () => bareAdmin.updateRole(
              const AccessRole(name: 'R', groups: {AccessGroup.operate})));
      expectRefusal(
          'BackendAccessAdmin.deleteRole', () => bareAdmin.deleteRole('R'));
      expectRefusal('BackendAccessAdmin.renameRole',
          () => bareAdmin.renameRole('R', 'R2'));
      expectRefusal(
          'BackendAccessAdmin.createUser',
          () => bareAdmin.createUser(const relay.NewUserParams(
              subject: 'u', password: 'long enough pw', grantedRole: 'R')));
      expectRefusal(
          'BackendAccessAdmin.deleteUser', () => bareAdmin.deleteUser('u'));
      expectRefusal('BackendAccessAdmin.setUserRole',
          () => bareAdmin.setUserRole('u', 'R'));
      expectRefusal('BackendAccessAdmin.setUserStationAccount',
          () => bareAdmin.setUserStationAccount('u', true));
      expectRefusal(
          'BackendAccessAdmin.setUserPassword',
          () => bareAdmin.setUserPassword(const relay.SetUserPasswordParams(
              subject: 'u', password: 'long enough pw')));
    });

    group('audit', () {
      expectRefusal('BackendAudit.entries',
          () => bareAudit.entries(const relay.AuditQueryParams()));
      expectRefusal('BackendAudit.memberCountsByAction',
          () => bareAudit.memberCountsByAction(const ['a']));
      expectRefusal(
          'BackendAudit.distinctWho', () => bareAudit.distinctWho());
    });

    test('anti-vacuity: with a database, the reads answer', () async {
      // The writes' with-database half is arm 2's anti-vacuity loop; the
      // reads get theirs here so the refusals above cannot be satisfied by
      // members that answer nothing anywhere.
      expect(await templates.list(), isA<List<AccessTemplate>>());
      expect(await templates.bindings(), isA<Map<String, String>>());
      expect(await templates.keysBoundTo('T'), isA<List<String>>());
      expect(await admin.roles(), isNotEmpty,
          reason: 'the seeded roles are in a fresh schema');
      expect(await admin.listUsers(), isA<List<UserSummary>>());
      expect(await audit.entries(const relay.AuditQueryParams()),
          isA<List<AuditRecord>>());
      expect(await audit.memberCountsByAction(const ['a']),
          isA<Map<String, int>>());
      expect(await audit.distinctWho(), isA<List<String>>());
    });
  });

  // 17-08 F-1 — the roster row carries the two columns the screen renders.
  test('listUsers answers the row\'s own createdAt, not a sentinel — the '
      'gateway users screen read 1970 for every account before this',
      () async {
    final before = DateTime.now().toUtc();
    await admin.createRole(
        const AccessRole(name: 'R_ts', groups: {AccessGroup.operate}));
    await admin.createUser(const relay.NewUserParams(
        subject: 'u_ts',
        password: 'a sufficiently long pw',
        grantedRole: 'R_ts'));

    final row = (await admin.listUsers())
        .firstWhere((u) => u.username == 'u_ts');
    expect(row.createdAt, isNotNull,
        reason: 'null here is what the panel renders as 1970');
    expect(row.createdAt!.isBefore(before), isFalse,
        reason: 'the account was created after this test started, so a '
            'created date before it is the sentinel leaking back in');
    expect(row.lastLoginAt, isNull,
        reason: 'a brand new account has never signed in, which the screen '
            'renders as "never"');
    expect(row.roleName, 'R_ts');
  });

  // The passwordless account, over the gateway path rather than the direct one.
  test('an empty password crosses the wire and creates an account that signs '
      'in on its username alone, marked so on the roster', () async {
    await admin.createRole(
        const AccessRole(name: 'R_np', groups: {AccessGroup.operate}));
    await admin.createUser(const relay.NewUserParams(
        subject: 'line', password: '', grantedRole: 'R_np'));

    // The row itself: the marker, not an empty column and not a hash.
    final stored = await AccessRepository(db).user('line');
    expect(stored, isNotNull);
    expect(isPasswordless(stored!.passwordHash), isTrue);
    expect(stored.salt, isEmpty);

    // And what the panel is told, which is the half a gateway station sees.
    final row = (await admin.listUsers()).firstWhere((u) => u.username == 'line');
    expect(row.hasPassword, isFalse,
        reason: 'a panel cannot mark an open account it is not told about');
    expect((await admin.listUsers()).every((u) => u.username == 'line' || u.hasPassword),
        isTrue,
        reason: 'and it must not mark the protected ones');
  });

  // The wire cut, its own arm rather than a members-table row.
  test('template(name) is cut from the wire and refuses by name, database '
      'or no database', () async {
    await expectLater(
      templates.template('T'),
      throwsA(isA<UnsupportedError>().having((e) => e.message, 'message',
          allOf(contains('template'), contains('list()')))),
      reason: 'a remote needing one template derives it from list(); this '
          'member must not quietly serve a surface the wire no longer has',
    );
  });

  // ---------------------------------------------------------------------------
  // Arm 7 — reads are ungated: read permissions are deferred, spec §11
  // ---------------------------------------------------------------------------

  test('arm 7: every read answers for a session holding nothing — read '
      'permissions are deferred, spec §11, not a hole', () async {
    await templates.create(_template('Readable'));
    await templates.bind('k.read', 'Readable');

    session = _holdingNothing;
    expect((await templates.list()).map((t) => t.name), contains('Readable'));
    expect(await templates.bindings(), containsPair('k.read', 'Readable'));
    expect(await templates.keysBoundTo('Readable'), ['k.read']);
    expect((await admin.roles()).map((r) => r.name), contains('Operator'));
    expect(await admin.listUsers(), isA<List<UserSummary>>());
    expect(await audit.entries(const relay.AuditQueryParams()), isNotEmpty,
        reason: 'the two writes above each left a row');
    expect(await audit.distinctWho(), contains('ST101-panel'));
  });

  // ---------------------------------------------------------------------------
  // Arm 8 — the last-users-holder invariant survives the trip
  // ---------------------------------------------------------------------------

  group('arm 8: the lockout invariant is the repository\'s, and it holds',
      () {
    test('deleting the only users-holding role, as a users session, is '
        'refused by the in-transaction check — not by a permission',
        () async {
      await admin.createRole(const AccessRole(
          name: 'Admins', groups: {AccessGroup.operate, AccessGroup.users}));
      await admin.createUser(const relay.NewUserParams(
          subject: 'alice',
          password: 'a sufficiently long pw',
          grantedRole: 'Admins'));

      await expectLater(
        admin.deleteRole('Admins'),
        throwsA(isA<LastUsersHolderException>()),
        reason: 'a users session was refused, so this is the domain rule '
            'crossing intact, not a permission check',
      );
      expect(denials, isEmpty,
          reason: 'no AccessDenied fired: the session held users');
    });

    test('anti-vacuity: a second users-holding role with no holders deletes '
        'fine while the first keeps its holder', () async {
      await admin.createRole(const AccessRole(
          name: 'Admins', groups: {AccessGroup.operate, AccessGroup.users}));
      await admin.createUser(const relay.NewUserParams(
          subject: 'alice',
          password: 'a sufficiently long pw',
          grantedRole: 'Admins'));
      await admin.createRole(const AccessRole(
          name: 'SpareAdmins',
          groups: {AccessGroup.operate, AccessGroup.users}));

      await admin.deleteRole('SpareAdmins');

      expect((await admin.roles()).map((r) => r.name),
          isNot(contains('SpareAdmins')));
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 9 — exception types cross intact
  // ---------------------------------------------------------------------------

  group('arm 9: the domain vocabulary is not flattened', () {
    test('TemplateInUseException arrives as itself, bound keys included',
        () async {
      await templates.create(_template('Bound'));
      await templates.bind('k.one', 'Bound');
      await templates.bind('k.two', 'Bound');

      await expectLater(
        templates.delete('Bound'),
        throwsA(isA<TemplateInUseException>()
            .having((e) => e.boundKeys, 'boundKeys', ['k.one', 'k.two'])),
        reason: 'a screen that says "failed" where it could say "still bound '
            'to 2 keys" is a regression from direct mode',
      );
    });

    test('TemplateNotFoundException arrives as itself', () async {
      await expectLater(
        templates.update(_template('NoSuch')),
        throwsA(isA<TemplateNotFoundException>()),
      );
    });

    test('UserNotFoundException arrives as itself', () async {
      await expectLater(
        admin.deleteUser('nobody'),
        throwsA(isA<UserNotFoundException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Arm 10 — no permission check of this file's own
  // ---------------------------------------------------------------------------

  group('arm 10: the mapping layer decides nothing', () {
    final source = File('lib/core/relay/backend_access.dart');

    test('backend_access.dart holds no AccessGroup. and no .can( outside '
        'comments — every decision belongs to the store', () {
      final lines = source
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .toList();
      final offending = lines
          .where((line) =>
              line.contains('AccessGroup.') || line.contains('.can('))
          .toList();
      expect(offending, isEmpty,
          reason: 'the phase\'s constitution, mechanically: a correct check '
              'in the wrong place is still a second gate. Offending lines: '
              '$offending');
    });

    test('anti-vacuity: the file was found and is over 150 lines', () {
      expect(source.existsSync(), isTrue);
      expect(source.readAsLinesSync().length, greaterThan(150),
          reason: 'a grep over an absent or trivial file proves nothing');
    });
  });
}

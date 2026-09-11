// The one gate over `app_role` and `app_user`.
//
// The write-path sweep §3.3 records `AccessRepository` writing both tables
// through raw Drift as the one write path deliberately left open, with "Phase 6
// gates it on `users`" as the closing condition. `AccessAdminStore` is that
// closure, and this file is what makes the claim checkable.
//
// The `configure`-only session is the important fixture here. It is the
// engineer who may edit pages and key mappings and who must **not** be able to
// grant themselves `users` and from there everything — and it is exactly the
// case `docs/access-control-deployment.md` §4 gets wrong when it calls user
// management an `administer` screen. Driving that session into every write is
// the difference between a gate that is checked and a gate that is remembered.
//
// Every "it did not happen" assertion reads the tables back through the
// repository rather than counting calls on a mock: the claim is that no
// statement was issued, and only the database can answer that. Where a claim is
// about *which repository method the store reached for*, a subclass of the real
// repository logs the call — the doctrine `_RecordingStore` and `_RacingStore`
// establish in `test/pages/access_templates_section_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tfc/core/access_admin_store.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/database_drift.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingSink implements AuditSink {
  final List<AuditRecord> rows = [];

  @override
  Future<void> record(AuditRecord entry) async => rows.add(entry);
}

/// A sink that fails every write, for the "the trail is not the write path"
/// tests.
class _ThrowingSink implements AuditSink {
  int calls = 0;

  @override
  Future<void> record(AuditRecord entry) async {
    calls++;
    throw StateError('the audit database blinked');
  }
}

/// The real repository, with a log of which methods the store reached for.
///
/// Subclassed rather than faked, for the reason `_RecordingStore` gives: the
/// claims about *what happened* are read back from the tables, and only the
/// claim about which method was called needs a log. A hand-written fake would
/// let "the repository is not called on a denial" pass while the store quietly
/// asked the database something else.
class _RecordingRepository extends AccessRepository {
  _RecordingRepository(super.db);

  final List<String> calls = [];

  @override
  Future<void> upsertRole(AccessRole role) {
    calls.add('upsertRole:${role.name}');
    return super.upsertRole(role);
  }

  @override
  Future<void> deleteRole(String name) {
    calls.add('deleteRole:$name');
    return super.deleteRole(name);
  }

  @override
  Future<void> renameRole(String from, String to) {
    calls.add('renameRole:$from->$to');
    return super.renameRole(from, to);
  }

  @override
  Future<void> createUser({
    required String username,
    required String password,
    required String roleName,
  }) {
    calls.add('createUser:$username');
    return super
        .createUser(username: username, password: password, roleName: roleName);
  }

  @override
  Future<void> deleteUser(String username) {
    calls.add('deleteUser:$username');
    return super.deleteUser(username);
  }

  @override
  Future<void> setRole(String username, String roleName) {
    calls.add('setRole:$username->$roleName');
    return super.setRole(username, roleName);
  }

  @override
  Future<void> setPassword(String username, String password) {
    calls.add('setPassword:$username');
    return super.setPassword(username, password);
  }

  @override
  Future<void> setRoleAllowedPages(String name, Set<String>? pages) {
    calls.add('setRoleAllowedPages:$name');
    return super.setRoleAllowedPages(name, pages);
  }

  @override
  Future<void> setUserAllowedPages(String username, Set<String>? pages) {
    calls.add('setUserAllowedPages:$username');
    return super.setUserAllowedPages(username, pages);
  }
}

/// A repository whose chosen write throws once, from inside the call.
///
/// This is how design decision 2 is pinned. The store records the allowed row
/// **after** the repository returns, so a write that blows up inside the
/// transaction must leave the trail empty. Move `_recordAllowed` above the
/// repository call and the tests using this double are the ones that catch it.
///
/// A subclass of the real repository rather than a mock, for the same reason
/// `_RacingStore` is: everything else in these tests still has to be the real
/// database behaving normally.
class _RefusingRepository extends _RecordingRepository {
  _RefusingRepository(super.db);

  /// Thrown by [upsertRole], once. Cleared after it fires.
  Object? failUpsertWith;

  @override
  Future<void> upsertRole(AccessRole role) async {
    final failure = failUpsertWith;
    if (failure != null) {
      failUpsertWith = null;
      calls.add('upsertRole:${role.name}');
      throw failure;
    }
    return super.upsertRole(role);
  }
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

/// Nobody signed in. Anonymous is Operator by construction (Phase 1).
AccessSession _anonymous() =>
    AccessSession.anonymous(const {AccessGroup.operate});

/// The engineer who can edit pages and key mappings — and must not be able to
/// decide who may do what.
///
/// This is the session the `users` gate exists for. `configure` is the highest
/// group a page editor needs, and every one of the eight writes in this store
/// must refuse it. It is also the session
/// `docs/access-control-deployment.md` §4 describes wrongly: it calls the
/// screen that creates users an `administer` screen, and this fixture holds
/// neither `administer` nor `users`, so the two spellings cannot be confused
/// by accident here.
AccessSession _configureOnly() => const AccessSession(
      user: AuthenticatedUser(username: 'engineer', roleName: 'Engineering'),
      groups: {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.configure,
      },
    );

/// The administrator who holds `users`.
AccessSession _withUsers() => const AccessSession(
      user: AuthenticatedUser(username: 'admin', roleName: 'Administrator'),
      groups: {AccessGroup.operate, AccessGroup.configure, AccessGroup.users},
    );

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

AccessRole _shiftLead() => const AccessRole(
      name: 'Line Lead',
      groups: {AccessGroup.operate, AccessGroup.setpoints},
    );

void main() {
  late AppDatabase db;
  late _RecordingRepository repository;
  late _RecordingSink sink;
  late List<AccessDenied> denials;
  late AccessSession session;

  AccessAdminStore buildStore({AuditSink? audit}) => AccessAdminStore(
        repository: repository,
        session: () => session,
        audit: audit ?? sink,
        station: 'SVN-NES-OT-CL02',
        onDenied: denials.add,
      );

  Future<int> roleRowCount() async {
    final row =
        await db.customSelect('SELECT COUNT(*) AS c FROM app_role').getSingle();
    return row.read<int>('c');
  }

  setUp(() async {
    // PBKDF2 at production iteration counts costs the better part of a second
    // per account; these tests create several.
    Pbkdf2Kdf.iterationsForTest = 10;
    db = AppDatabase.inMemoryForTest();
    // Force the schema — and with it the four seeded roles — to exist before
    // the first store call, so a row count read back on the deny path is
    // reading a real table rather than failing to find one.
    await db.customSelect('SELECT 1').getSingle();
    repository = _RecordingRepository(db);
    sink = _RecordingSink();
    denials = [];
    session = _withUsers();
  });

  tearDown(() async {
    Pbkdf2Kdf.iterationsForTest = null;
    await db.close();
  });

  // -------------------------------------------------------------------------
  // The constant
  // -------------------------------------------------------------------------

  group('kAccessAdminGroup', () {
    test('is users, and is the only group this store names', () {
      expect(
        kAccessAdminGroup,
        AccessGroup.users,
        reason: 'spec §1 gates role and user management on `users`. '
            "docs/access-control-deployment.md §4 says \"screens behind the "
            '`administer` group, including the screen that creates users", '
            'which is a factual error in the doc — plan 06-05 fixes the '
            'sentence and this assertion is what the code says instead. '
            'Lowering this line to `configure` would let anybody who can edit '
            'a page grant themselves `users`, and from there everything, '
            'which is the exact confusion the group split exists to prevent.',
      );
    });

    test('every row this store writes names it as the group required',
        () async {
      final store = buildStore();
      await store.createRole(_shiftLead());
      expect(sink.rows.single.groupRequired, AccessGroup.users.name);
    });
  });

  // -------------------------------------------------------------------------
  // The file itself
  // -------------------------------------------------------------------------

  group('the store owns no queries', () {
    test('imports no Drift', () {
      final source =
          File('lib/core/access_admin_store.dart').readAsStringSync();
      expect(
        source.contains('package:drift'),
        isFalse,
        reason: 'the transaction and every invariant that must run inside it '
            'live in AccessRepository. A method here that needs a Value() or '
            'a Companion belongs one layer down.',
      );
    });

    test('builds no bare AuditRecord', () {
      final source = File('lib/core/access_admin_store.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        RegExp(r'AuditRecord\(').hasMatch(source),
        isFalse,
        reason: 'the eight named constructors fix the itemKey vocabulary in '
            'one place; a ninth row shape invented here is the vocabulary '
            'drifting on day one.',
      );
    });
  });

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  group('reads', () {
    test('roles returns the seeded rows and records nothing, anonymous',
        () async {
      session = _anonymous();
      final store = buildStore();

      final roles = await store.roles();

      expect(
          roles.map((r) => r.name), containsAll(kSeedRoles.map((r) => r.name)));
      expect(sink.rows, isEmpty,
          reason: 'a row per render would bury the writes that matter, and '
              'the route gate is the enforcement for reads.');
      expect(denials, isEmpty);
    });

    test('listUsers returns the accounts and records nothing, anonymous',
        () async {
      await repository.createUser(
          username: 'jon', password: 'hunter2!', roleName: 'Engineering');
      session = _anonymous();
      final store = buildStore();

      final users = await store.listUsers();

      expect(users.map((u) => u.username), ['jon']);
      expect(sink.rows, isEmpty);
      expect(denials, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The gate, through the first write
  // -------------------------------------------------------------------------

  group('the gate', () {
    test('a users holder is let through and one allowed row is recorded',
        () async {
      final store = buildStore();

      await store.createRole(_shiftLead(), reason: 'new line');

      final row = sink.rows.single;
      expect(row.allowed, isTrue);
      expect(row.surface, 'admin');
      expect(row.itemKey, 'role.create');
      expect(row.member, 'Line Lead');
      expect(row.who, 'admin');
      expect(row.station, 'SVN-NES-OT-CL02');
      expect(row.roleName, 'Administrator');
      expect(row.reason, 'new line');
      expect(row.origin, 'operator');
      expect(row.newValue, _shiftLead().encodeGroups());
      expect(await repository.role('Line Lead'), isNotNull);
    });

    test('a configure-only session is refused, and nothing is written',
        () async {
      session = _configureOnly();
      final store = buildStore();
      final before = await roleRowCount();

      await expectLater(
        () => store.createRole(_shiftLead()),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', 'role.create')
            .having((d) => d.required, 'required', AccessGroup.users)),
      );

      expect(await roleRowCount(), before);
      expect(repository.calls, isEmpty,
          reason: 'the gate runs before the repository is reached at all.');
    });

    test('the deny row is recorded before the throw', () async {
      session = _configureOnly();
      final store = buildStore();

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<AccessDenied>()));

      final row = sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.itemKey, 'role.create');
      expect(row.member, 'Line Lead');
      expect(row.who, 'engineer');
      expect(row.roleName, 'Engineering');
      expect(row.groupRequired, AccessGroup.users.name);
    });

    test('the deny row exists by the time onDenied fires', () async {
      session = _configureOnly();
      var rowsWhenNotified = -1;
      final store = AccessAdminStore(
        repository: repository,
        session: () => session,
        audit: sink,
        station: 'SVN-NES-OT-CL02',
        onDenied: (_) => rowsWhenNotified = sink.rows.length,
      );

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<AccessDenied>()));

      expect(rowsWhenNotified, 1,
          reason: 'a deny row is the only evidence the guard fired, so it is '
              'recorded before anything else can swallow the refusal.');
    });

    test(
        'an onDenied listener that throws does not change what the caller sees',
        () async {
      session = _configureOnly();
      final store = AccessAdminStore(
        repository: repository,
        session: () => session,
        audit: sink,
        station: 'SVN-NES-OT-CL02',
        onDenied: (_) => throw StateError('the prompt blew up'),
      );

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<AccessDenied>()));
      expect(sink.rows.single.allowed, isFalse);
    });

    test('the session is read at the moment of the call, not at construction',
        () async {
      session = _withUsers();
      final store = buildStore();
      // The inactivity monitor drops the operator back to anonymous while the
      // page is still open. A captured session would keep granting `users`.
      session = _anonymous();

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<AccessDenied>()));
      expect(sink.rows.single.who, 'anonymous');
      expect(sink.rows.single.roleName, kOperatorRoleName);
    });
  });

  // -------------------------------------------------------------------------
  // The sink is not the write path
  // -------------------------------------------------------------------------

  group('a failing audit sink', () {
    test('AUDIT ROW LOST: the permitted write still succeeds', () async {
      final throwing = _ThrowingSink();
      final store = buildStore(audit: throwing);

      await store.createRole(_shiftLead());

      expect(throwing.calls, 1);
      expect(await repository.role('Line Lead'), isNotNull,
          reason: 'a lost row is a log line, never a failed write.');
    });

    test('AUDIT ROW LOST: the refusal is still an AccessDenied', () async {
      session = _configureOnly();
      final throwing = _ThrowingSink();
      final store = buildStore(audit: throwing);

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<AccessDenied>()));

      expect(throwing.calls, 1);
      expect(denials, hasLength(1),
          reason: 'a sink failure must not skip onDenied and leave the '
              'operator with a control that did nothing and no explanation.');
    });
  });

  // -------------------------------------------------------------------------
  // The eight writes: what a permitted one records
  // -------------------------------------------------------------------------

  group('role writes', () {
    test('createRole records role.create with the new group set', () async {
      final store = buildStore();

      await store.createRole(_shiftLead(), reason: 'new line opened');

      expect(repository.calls, ['upsertRole:Line Lead']);
      final row = sink.rows.single;
      expect(row.itemKey, 'role.create');
      expect(row.member, 'Line Lead');
      expect(row.oldValue, isNull);
      expect(row.newValue, _shiftLead().encodeGroups());
      expect(row.reason, 'new line opened');
      expect((await repository.role('Line Lead'))!.groups, _shiftLead().groups);
    });

    test('createRole refuses a name that already exists, recording nothing',
        () async {
      await repository.upsertRole(_shiftLead());
      repository.calls.clear();
      final store = buildStore();

      await expectLater(
        () => store.createRole(_shiftLead()),
        throwsA(isA<ArgumentError>()),
        reason: 'upsertRole would quietly turn this into an update, and the '
            'row would then say role.create for something that created '
            'nothing.',
      );
      expect(sink.rows, isEmpty);
      expect(repository.calls, isEmpty);
    });

    test('updateRole records role.update with old and new group sets',
        () async {
      await repository.upsertRole(_shiftLead());
      final store = buildStore();

      await store.updateRole(const AccessRole(
        name: 'Line Lead',
        groups: {AccessGroup.operate, AccessGroup.setpoints, AccessGroup.force},
      ));

      final row = sink.rows.single;
      expect(row.itemKey, 'role.update');
      expect(row.member, 'Line Lead');
      expect(row.oldValue, _shiftLead().encodeGroups(),
          reason: 'the old value has to be read before the write, which is '
              'why it is read before the gate: a read is not an '
              'authorization event.');
      expect(
        row.newValue,
        const AccessRole(name: 'Line Lead', groups: {
          AccessGroup.operate,
          AccessGroup.setpoints,
          AccessGroup.force,
        }).encodeGroups(),
      );
    });

    test('setRolePages records role.pages, with null as a legible value',
        () async {
      await repository.upsertRole(_shiftLead());
      final store = buildStore();

      await store.setRolePages('Line Lead', {'/', '/fillet'});

      final row = sink.rows.single;
      expect(row.itemKey, 'role.pages');
      expect(row.member, 'Line Lead');
      expect(row.oldValue, isNull,
          reason: 'null is the meaningful "no whitelist" state, so the row '
              'reads null -> [...] when the mode is switched on');
      expect(row.newValue, '["/","/fillet"]');
      expect(row.allowed, isTrue);
      expect((await repository.role('Line Lead'))!.allowedPages,
          {'/', '/fillet'});
    });

    test('setRolePages records the switch back off as array -> null', () async {
      await repository.upsertRole(_shiftLead());
      await repository.setRoleAllowedPages('Line Lead', {'/'});
      final store = buildStore();

      await store.setRolePages('Line Lead', null);

      final row = sink.rows.single;
      expect(row.oldValue, '["/"]');
      expect(row.newValue, isNull);
      expect((await repository.role('Line Lead'))!.allowedPages, isNull);
    });

    test('setRolePages records block-all as an empty array, not as null',
        () async {
      // The state the feature was asked for by name. If this recorded null the
      // trail could not tell "sees nothing" from "sees everything".
      await repository.upsertRole(_shiftLead());
      final store = buildStore();

      await store.setRolePages('Line Lead', <String>{});

      expect(sink.rows.single.newValue, '[]');
      expect((await repository.role('Line Lead'))!.allowedPages, isEmpty);
    });

    test('setRolePages naming no role throws and writes nothing', () async {
      final store = buildStore();
      await expectLater(
        () => store.setRolePages('Nobody', {'/'}),
        throwsA(isA<MissingRoleError>()),
      );
      expect(sink.rows, isEmpty);
    });

    test('setUserPages records user.pages on the account, not the role',
        () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      final store = buildStore();

      await store.setUserPages('bob', {'/fillet'});

      final row = sink.rows.single;
      expect(row.itemKey, 'user.pages');
      expect(row.member, 'bob');
      expect(row.oldValue, isNull);
      expect(row.newValue, '["/fillet"]');
      expect((await repository.user('bob'))!.allowedPages, '["/fillet"]');
    });

    test('setUserPages naming no account throws and writes nothing', () async {
      final store = buildStore();
      await expectLater(
        () => store.setUserPages('nobody', {'/'}),
        throwsA(isA<UserNotFoundException>()),
      );
      expect(sink.rows, isEmpty);
    });

    test('updateRole refuses a role that does not exist, recording nothing',
        () async {
      final store = buildStore();

      await expectLater(
        () => store.updateRole(_shiftLead()),
        throwsA(isA<MissingRoleError>()),
        reason: 'upsertRole would insert it, and the row would say '
            'role.update for a create.',
      );
      expect(sink.rows, isEmpty);
      expect(repository.calls, isEmpty);
    });

    test('deleteRole records role.delete carrying what the role granted',
        () async {
      await repository.upsertRole(_shiftLead());
      final store = buildStore();

      await store.deleteRole('Line Lead');

      final row = sink.rows.single;
      expect(row.itemKey, 'role.delete');
      expect(row.member, 'Line Lead');
      expect(row.oldValue, _shiftLead().encodeGroups(),
          reason: 'the row still says what was lost after the row it '
              'described is gone.');
      expect(row.newValue, isNull);
      expect(await repository.role('Line Lead'), isNull);
    });

    test('deleteRole refuses a role that does not exist, recording nothing',
        () async {
      final store = buildStore();

      await expectLater(
          () => store.deleteRole('Nonesuch'), throwsA(isA<MissingRoleError>()));
      expect(sink.rows, isEmpty);
      expect(repository.calls, isEmpty);
    });

    test('renameRole records role.rename with both names', () async {
      await repository.upsertRole(_shiftLead());
      final store = buildStore();

      await store.renameRole('Line Lead', 'Line Leader');

      final row = sink.rows.single;
      expect(row.itemKey, 'role.rename');
      expect(row.member, 'Line Lead',
          reason: 'the member is the name the rest of the trail up to this '
              'point refers to.');
      expect(row.oldValue, 'Line Lead');
      expect(row.newValue, 'Line Leader');
      expect(await repository.role('Line Leader'), isNotNull);
    });
  });

  group('user writes', () {
    test('createUser records user.create naming the role granted', () async {
      final store = buildStore();

      await store.createUser(
        username: 'bob',
        password: 'correct-horse',
        roleName: 'Shift Leader',
      );

      final row = sink.rows.single;
      expect(row.itemKey, 'user.create');
      expect(row.member, 'bob');
      expect(row.oldValue, isNull);
      expect(row.newValue, 'Shift Leader');
      expect((await repository.listUsers()).single.username, 'bob');
    });

    test('deleteUser records user.delete naming the role held', () async {
      await repository.createUser(
          username: 'admin1', password: 'pw1', roleName: 'Engineering');
      await repository.createUser(
          username: 'bob', password: 'pw2', roleName: 'Shift Leader');
      repository.calls.clear();
      final store = buildStore();

      await store.deleteUser('bob');

      final row = sink.rows.single;
      expect(row.itemKey, 'user.delete');
      expect(row.member, 'bob');
      expect(row.oldValue, 'Shift Leader');
      expect(row.newValue, isNull);
      expect((await repository.listUsers()).map((u) => u.username), ['admin1']);
    });

    test('setUserRole records user.role with the old and the new role',
        () async {
      await repository.createUser(
          username: 'bob', password: 'pw2', roleName: 'Shift Leader');
      repository.calls.clear();
      final store = buildStore();

      await store.setUserRole('bob', 'Maintenance');

      final row = sink.rows.single;
      expect(row.itemKey, 'user.role');
      expect(row.member, 'bob');
      expect(row.oldValue, 'Shift Leader');
      expect(row.newValue, 'Maintenance');
    });

    test('setUserStationAccount records user.station_account with the flip',
        () async {
      await repository.createUser(
          username: 'freezer', password: 'pw2', roleName: 'Shift Leader');
      repository.calls.clear();
      final store = buildStore();

      await store.setUserStationAccount('freezer', true);

      final row = sink.rows.single;
      expect(row.itemKey, 'user.station_account');
      expect(row.member, 'freezer');
      expect(row.oldValue, 'false');
      expect(row.newValue, 'true');
      expect(
          (await repository.listUsers())
              .singleWhere((u) => u.username == 'freezer')
              .stationAccount,
          isTrue);
    });

    test('setUserInactivityTimeout records user.inactivity_timeout with the '
        'minutes', () async {
      await repository.createUser(
          username: 'bob', password: 'pw2', roleName: 'Shift Leader');
      repository.calls.clear();
      final store = buildStore();

      await store.setUserInactivityTimeout('bob', 45);

      final row = sink.rows.single;
      expect(row.itemKey, 'user.inactivity_timeout');
      expect(row.member, 'bob');
      expect(row.oldValue, isNull,
          reason: 'null is the meaningful "no value of its own", exactly as '
              'it is on the user.pages rows');
      expect(row.newValue, '45');
      expect(
          (await repository.listUsers()).single.inactivityTimeoutMinutes, 45);
    });

    test('clearing the timeout records the move back to the default',
        () async {
      await repository.createUser(
          username: 'bob', password: 'pw2', roleName: 'Shift Leader');
      await repository.setInactivityTimeout('bob', 45);
      repository.calls.clear();
      final store = buildStore();

      await store.setUserInactivityTimeout('bob', null);

      final row = sink.rows.single;
      expect(row.oldValue, '45');
      expect(row.newValue, isNull);
      expect((await repository.listUsers()).single.inactivityTimeoutMinutes,
          isNull);
    });

    test('setUserPassword records user.password and nothing about the password',
        () async {
      const secret = 'zXq7-never-in-a-row';
      await repository.createUser(
          username: 'bob', password: 'pw2', roleName: 'Shift Leader');
      repository.calls.clear();
      final store = buildStore();

      await store.setUserPassword('bob', secret);

      final row = sink.rows.single;
      expect(row.itemKey, 'user.password');
      expect(row.member, 'bob');
      expect(row.oldValue, isNull,
          reason: 'AuditRecord.userPassword leaves the value columns null by '
              'construction — there is no parameter that could fill them.');
      expect(row.newValue, isNull);
      for (final recorded in sink.rows) {
        expect(recorded.toString().contains(secret), isFalse);
        expect(
          [
            recorded.oldValue,
            recorded.newValue,
            recorded.member,
            recorded.reason,
            recorded.itemKey,
            recorded.who,
          ].any((v) => v != null && v.contains(secret)),
          isFalse,
          reason: 'an admin row is not an auth row, so toString does not '
              'withhold its value columns — they reach log files that live '
              'longer and travel further than the database does.',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // T-06-20: a configure-only session, driven into every one of the eight
  // -------------------------------------------------------------------------

  group('a configure-only session is refused by every write', () {
    /// Runs [write] under the engineer session and asserts the whole refusal:
    /// [AccessDenied] naming [itemKey], exactly one denied row carrying the
    /// same key, and a repository that was never reached.
    Future<void> expectGated(
      String itemKey,
      Future<void> Function(AccessAdminStore store) write,
    ) async {
      session = _configureOnly();
      final store = buildStore();

      await expectLater(
        () => write(store),
        throwsA(isA<AccessDenied>()
            .having((d) => d.itemKey, 'itemKey', itemKey)
            .having((d) => d.required, 'required', AccessGroup.users)),
      );

      final row = sink.rows.single;
      expect(row.allowed, isFalse);
      expect(row.itemKey, itemKey,
          reason: 'the itemKey the gate throws and the itemKey the row '
              'carries are two spellings of one string, and they are checked '
              'against each other rather than trusted.');
      expect(row.surface, 'admin');
      expect(row.groupRequired, AccessGroup.users.name);
      expect(row.who, 'engineer');
      expect(denials.single.itemKey, itemKey);
      expect(repository.calls, isEmpty,
          reason: 'the gate runs before the repository is reached at all.');
    }

    test('createRole',
        () => expectGated('role.create', (s) => s.createRole(_shiftLead())));

    test('updateRole', () async {
      await repository.upsertRole(_shiftLead());
      repository.calls.clear();
      await expectGated('role.update', (s) => s.updateRole(_shiftLead()));
    });

    test('deleteRole', () async {
      await repository.upsertRole(_shiftLead());
      repository.calls.clear();
      await expectGated('role.delete', (s) => s.deleteRole('Line Lead'));
    });

    test('renameRole', () async {
      await repository.upsertRole(_shiftLead());
      repository.calls.clear();
      await expectGated(
          'role.rename', (s) => s.renameRole('Line Lead', 'Line Leader'));
    });

    test('createUser', () async {
      await expectGated(
        'user.create',
        (s) => s.createUser(
            username: 'bob', password: 'pw', roleName: 'Shift Leader'),
      );
      expect(await repository.listUsers(), isEmpty);
    });

    test('deleteUser', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      repository.calls.clear();
      await expectGated('user.delete', (s) => s.deleteUser('bob'));
      expect((await repository.listUsers()).single.username, 'bob');
    });

    test('setUserRole', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      repository.calls.clear();
      await expectGated(
          'user.role', (s) => s.setUserRole('bob', 'Maintenance'));
      expect((await repository.listUsers()).single.roleName, 'Shift Leader');
    });

    test('setUserStationAccount', () async {
      await repository.createUser(
          username: 'freezer', password: 'pw', roleName: 'Shift Leader');
      repository.calls.clear();
      await expectGated('user.station_account',
          (s) => s.setUserStationAccount('freezer', true));
      expect((await repository.listUsers()).single.stationAccount, isFalse);
    });

    test('setUserInactivityTimeout', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      repository.calls.clear();
      await expectGated('user.inactivity_timeout',
          (s) => s.setUserInactivityTimeout('bob', 45));
      expect((await repository.listUsers()).single.inactivityTimeoutMinutes,
          isNull);
    });

    test('setUserPassword', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      final before = (await repository.listUsers()).single.passwordHash;
      repository.calls.clear();
      await expectGated(
          'user.password', (s) => s.setUserPassword('bob', 'new-one'));
      expect((await repository.listUsers()).single.passwordHash, before);
    });

    test('setRolePages', () async {
      await repository.upsertRole(_shiftLead());
      repository.calls.clear();
      await expectGated('role.pages', (s) => s.setRolePages('Line Lead', {'/'}));
      expect((await repository.role('Line Lead'))!.allowedPages, isNull,
          reason: 'a refused whitelist edit must not reach the column');
    });

    test('setUserPages', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      repository.calls.clear();
      await expectGated('user.pages', (s) => s.setUserPages('bob', {'/'}));
      expect((await repository.user('bob'))!.allowedPages, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // T-06-22: a write the repository refused leaves nothing behind
  // -------------------------------------------------------------------------

  group('a refused write records no row', () {
    test('LastUsersHolderException: deleting the last users holder', () async {
      await repository.createUser(
          username: 'admin1', password: 'pw', roleName: 'Engineering');
      final store = buildStore();

      await expectLater(
        () => store.deleteUser('admin1'),
        throwsA(isA<LastUsersHolderException>()
            .having((e) => e.holders, 'holders', ['admin1'])),
        reason: 'the refusal is rethrown unchanged: the holder list is what '
            'the dialog renders, and re-wrapping it is how that list stops '
            'reaching the dialog.',
      );
      expect(sink.rows, isEmpty,
          reason: 'the invariant is evaluated inside the repository '
              'transaction, which is precisely the condition this layer '
              'cannot pre-check. So the allowed row is written after the call '
              'returns, and a refusal leaves nothing claiming it happened.');
      expect((await repository.listUsers()).single.username, 'admin1');
    });

    test('LastUsersHolderException: unticking users from the only role',
        () async {
      await repository.createUser(
          username: 'admin1', password: 'pw', roleName: 'Engineering');
      final store = buildStore();

      await expectLater(
        () => store.updateRole(const AccessRole(
          name: 'Engineering',
          groups: {AccessGroup.operate, AccessGroup.configure},
        )),
        throwsA(isA<LastUsersHolderException>()),
      );
      expect(sink.rows, isEmpty);
    });

    test('RoleInUseException: deleting a role accounts still hold', () async {
      await repository.upsertRole(_shiftLead());
      await repository.createUser(
          username: 'carl', password: 'pw', roleName: 'Line Lead');
      final store = buildStore();

      await expectLater(
        () => store.deleteRole('Line Lead'),
        throwsA(isA<RoleInUseException>()
            .having((e) => e.holders, 'holders', ['carl'])),
      );
      expect(sink.rows, isEmpty);
      expect(await repository.role('Line Lead'), isNotNull);
    });

    test('UserExistsException: creating an account twice', () async {
      await repository.createUser(
          username: 'bob', password: 'pw', roleName: 'Shift Leader');
      final store = buildStore();

      await expectLater(
        () => store.createUser(
            username: 'bob', password: 'pw2', roleName: 'Maintenance'),
        throwsA(isA<UserExistsException>()),
      );
      expect(sink.rows, isEmpty);
      expect((await repository.listUsers()).single.roleName, 'Shift Leader');
    });

    test('UserNotFoundException: resetting an absent account password',
        () async {
      final store = buildStore();

      await expectLater(
        () => store.setUserPassword('nobody', 'pw'),
        throwsA(isA<UserNotFoundException>()),
      );
      expect(sink.rows, isEmpty);
    });

    test('ProtectedRoleError: deleting Operator', () async {
      final store = buildStore();

      await expectLater(
        () => store.deleteRole(kOperatorRoleName),
        throwsA(isA<ProtectedRoleError>()),
        reason: 'it is an Error because reaching it means a caller skipped a '
            'check; a screen offering a Delete on the Operator row must fail '
            'loudly rather than be swallowed here.',
      );
      expect(sink.rows, isEmpty);
      expect(await repository.role(kOperatorRoleName), isNotNull);
    });

    test('the allowed row is written after the repository call returns',
        () async {
      repository = _RefusingRepository(db)
        ..failUpsertWith = StateError('the transaction rolled back');
      final store = buildStore();

      await expectLater(
          () => store.createRole(_shiftLead()), throwsA(isA<StateError>()));

      expect(repository.calls, ['upsertRole:Line Lead'],
          reason: 'the gate passed and the repository was reached.');
      expect(sink.rows, isEmpty,
          reason: 'nothing may claim a write that did not commit. If this '
              'fails, somebody moved _recordAllowed above the repository '
              'call.');
    });
  });

  // -------------------------------------------------------------------------
  // Reason and origin
  // -------------------------------------------------------------------------

  group('reason and origin', () {
    test('a null reason is recorded as null, not as an invented default',
        () async {
      final store = buildStore();
      await store.createRole(_shiftLead());
      expect(sink.rows.single.reason, isNull);
    });

    test('origin is the only caller-settable field on the row', () async {
      final store = buildStore();
      await store.createRole(_shiftLead(), origin: 'mcp', reason: 'proposal');
      final row = sink.rows.single;
      expect(row.origin, 'mcp');
      expect(row.who, 'admin',
          reason: 'the row names the human who approved it, never the agent '
              'that suggested it.');
    });
  });
}

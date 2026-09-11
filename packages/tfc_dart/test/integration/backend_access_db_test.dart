/// 17-06's real-Postgres leg: the rows actually land.
///
/// The in-memory leg (`test/core/relay/backend_access_test.dart`) proves the
/// wiring; this proves the schema. Three arms, each read back **with SQL**
/// rather than through the store that wrote it, because "the row landed" is a
/// claim about the table and only the table can answer it:
///
///  1. a gateway-mode role creation writes a real `app_role` row and a real
///     `audit_entry` row with `origin = 'relay'`
///  2. a refused write leaves an `audit_entry` deny row and **no** `app_role`
///     row — both halves asserted with SQL
///  3. a direct-mode write and a gateway-mode write land in **one**
///     `audit_entry` table, returned by one `SELECT`, distinguishable only by
///     `origin` — criterion 3's literal claim, asserted in the one place it is
///     actually true or false
///
/// ## Hygiene
///
/// `app_role` and `audit_entry` are drift's own schema and cannot be prefixed,
/// so every row this file writes carries a per-run random [suffix] in its role
/// name, its `who` and its `station`, and `tearDownAll` deletes by that
/// suffix. The database container is shared across this run's suites
/// (`docker_compose.dart`'s pid-scoped project), so leaving rows behind would
/// leak into a sibling suite's counts.
@Tags(['db'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/access/access_admin_store.dart';
import 'package:tfc_dart/core/access/access_repository.dart';
import 'package:tfc_dart/core/access/drift_audit_sink.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/relay/backend_access.dart';

import 'docker_compose.dart';

/// The per-run marker every row this file writes carries.
final String suffix =
    Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

late Database writer;
bool fixtureUp = false;

void main() {
  final station = 'IT1706-$suffix';
  final gatewayWho = 'gw-panel-$suffix';
  final panelWho = 'panel-op-$suffix';

  /// The station account a relay session resolves to, holding `users` so the
  /// permitted arms can write.
  final stationSession = AccessSession(
    user: AuthenticatedUser(
      username: gatewayWho,
      roleName: 'Panel Admin',
      stationAccount: true,
    ),
    groups: const {AccessGroup.operate, AccessGroup.users},
  );

  /// The page editor the deny arm drives: `configure` and below, no `users`.
  final configureOnly = AccessSession(
    user: AuthenticatedUser(username: gatewayWho, roleName: 'Engineering'),
    groups: const {AccessGroup.operate, AccessGroup.configure},
  );

  late AccessSession session;

  setUpAll(() async {
    await startDockerCompose();
    await waitForDatabaseReady();
    writer = await connectToDatabase();
    fixtureUp = true;
  });

  tearDownAll(() async {
    if (!fixtureUp) return;
    // Delete by this run's marker only: seeded roles and sibling suites' rows
    // stay untouched.
    await writer.db.customStatement(
        "DELETE FROM audit_entry WHERE station = '$station'");
    await writer.db.customStatement(
        "DELETE FROM app_role WHERE name LIKE 'gw_%_$suffix'");
    await writer.close();
  });

  setUp(() {
    session = stationSession;
  });

  BackendAccessAdmin gatewayAdmin() => BackendAccessAdmin(
        database: writer.db,
        session: () => session,
        station: station,
        audit: DriftAuditSink(writer.db),
      );

  Future<int> count(String sql) async {
    final row = await writer.db.customSelect(sql).getSingle();
    return row.read<int>('c');
  }

  test('a gateway-mode role creation writes a real app_role row and a real '
      'audit_entry row with origin = relay', () async {
    final role = 'gw_created_$suffix';

    await gatewayAdmin().createRole(
        AccessRole(name: role, groups: const {AccessGroup.operate}));

    expect(
      await count(
          "SELECT COUNT(*) AS c FROM app_role WHERE name = '$role'"),
      1,
      reason: 'the store the panel uses wrote the same table it always '
          'writes, reached through the backend',
    );

    final auditRows = await writer.db
        .customSelect("SELECT who, station, role_name, origin, allowed "
            "FROM audit_entry WHERE item_key = 'role.create' "
            "AND member = '$role'")
        .get();
    expect(auditRows, hasLength(1));
    final row = auditRows.single;
    expect(row.read<String>('origin'), 'relay');
    expect(row.read<bool>('allowed'), isTrue);
    expect(row.read<String>('who'), gatewayWho);
    expect(row.read<String>('station'), station);
    expect(row.read<String>('role_name'), 'Panel Admin');
  });

  test('a refused write leaves an audit_entry deny row and NO app_role row',
      () async {
    final role = 'gw_denied_$suffix';

    session = configureOnly;
    await expectLater(
      gatewayAdmin().createRole(
          AccessRole(name: role, groups: const {AccessGroup.operate})),
      throwsA(isA<AccessDenied>()),
    );

    expect(
      await count(
          "SELECT COUNT(*) AS c FROM app_role WHERE name = '$role'"),
      0,
      reason: 'the refusal is pre-effect: nothing reached the table',
    );
    final denyRows = await writer.db
        .customSelect("SELECT origin, allowed FROM audit_entry "
            "WHERE item_key = 'role.create' AND member = '$role'")
        .get();
    expect(denyRows, hasLength(1),
        reason: 'a refusal that leaves no trace is the one kind of guard '
            'nobody can audit afterwards');
    expect(denyRows.single.read<bool>('allowed'), isFalse);
    expect(denyRows.single.read<String>('origin'), 'relay');
  });

  test('a direct-mode write and a gateway-mode write land in ONE audit_entry '
      'table, distinguishable only by origin', () async {
    // The gateway leg: the backend family over the relay identity.
    await gatewayAdmin().createRole(AccessRole(
        name: 'gw_sametable_$suffix', groups: const {AccessGroup.operate}));

    // The direct leg: the store constructed the app's way — the same class,
    // the default origin, an operator session at the same (test) station.
    final panelStore = AccessAdminStore(
      repository: AccessRepository(writer.db),
      session: () => AccessSession(
        user: AuthenticatedUser(username: panelWho, roleName: 'Admin'),
        groups: const {AccessGroup.operate, AccessGroup.users},
      ),
      audit: DriftAuditSink(writer.db),
      station: station,
    );
    await panelStore.createRole(AccessRole(
        name: 'gw_direct_$suffix', groups: const {AccessGroup.operate}));

    // One SELECT, both rows.
    final rows = await writer.db
        .customSelect("SELECT who, origin FROM audit_entry "
            "WHERE station = '$station' AND item_key = 'role.create' "
            "AND member IN ('gw_sametable_$suffix', 'gw_direct_$suffix') "
            "ORDER BY id")
        .get();
    expect(rows, hasLength(2),
        reason: 'one table holds both trails — there is no second '
            'audit_entry for the wire');
    expect(rows.map((r) => r.read<String>('origin')).toSet(),
        {'relay', 'operator'},
        reason: 'the transport is the only thing telling the rows apart');
    expect(rows.first.read<String>('who'), gatewayWho);
    expect(rows.last.read<String>('who'), panelWho);
  });
}

// Schema v6 — the access control tables, their migration and their seed.
//
// SQLite only. The `from < 6` branch's Postgres arm is raw
// `CREATE TABLE IF NOT EXISTS` DDL and is not exercised here: a live server is
// needed for that and CI's tfc-dart-test job already provisions one.
//
// TODO(phase-1): add a Postgres migration assertion to
// `test/integration/database_integration_test.dart` — open a v5 database,
// upgrade it, and assert `app_role` / `app_user` / `audit_entry` exist with the
// three indexes. Until then the Postgres DDL in the `from < 6` branch is only
// covered by that job running the app against a real server, which means a
// column-name typo in it would not be caught by this file.

import 'dart:io';

// `isNull` is a matcher here, not drift's SQL expression of the same name.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_access/tfc_access.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

/// Returns the set of user table names in the given [db].
///
/// Copied from `database_migration_test.dart` rather than shared: it is
/// private to that file, and two independent copies keep the two suites from
/// failing together for one reason.
Future<Set<String>> _tableNames(GeneratedDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// Returns the set of index names in the given [db].
Future<Set<String>> _indexNames(GeneratedDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// The three tables added by the v5→v6 migration.
const _accessTables = ['app_role', 'app_user', 'audit_entry'];

/// Undoes what schema **v7** added to `alarm_history`.
///
/// The v5 fixtures in this repository are built by creating the CURRENT schema
/// and removing what came later, so every future version has to add its own
/// rollback here or the fixture is not the shape it claims to be. Without
/// these, `onUpgrade(5, 7)`'s SQLite arm aborts on
/// `duplicate column name: rule_index` — the fixture, not the migration: a
/// real v5 SQLite database has none of these.
///
/// The index goes first. SQLite refuses to drop a column an index refers to.
const _v7Rollback = [
  'DROP INDEX IF EXISTS idx_alarm_history_open',
  'ALTER TABLE alarm_history DROP COLUMN rule_index',
  'ALTER TABLE alarm_history DROP COLUMN ts_source',
  'ALTER TABLE alarm_history DROP COLUMN deactivated_reason',
];

/// The three `audit_entry` indexes.
const _auditIndexes = [
  'idx_audit_entry_at',
  'idx_audit_entry_item_key_at',
  'idx_audit_entry_who_at',
];

/// The seeded roles as `{name: groups}`, read straight out of `app_role`.
Future<Map<String, Set<AccessGroup>>> _roles(GeneratedDatabase db) async {
  final rows = await db.customSelect('SELECT * FROM app_role').get();
  return {
    for (final r in rows)
      r.read<String>('name'): AccessRole.decodeGroups(r.read<String>('groups')),
  };
}

void main() {
  group('fresh install', () {
    test('creates app_role, app_user and audit_entry', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final tables = await _tableNames(db);
      for (final table in _accessTables) {
        expect(tables, contains(table),
            reason: 'access table "$table" should exist on a fresh install');
      }
    });

    // The access milestone is one version, not three: it was developed as v6,
    // v7 and v8 and squash-merged, so `access_template` /
    // `access_key_binding` (`access_template_table_test.dart`) and
    // `app_user.station_account` (`station_account_column_test.dart`) all
    // arrive in the same v6 arm this suite covers.
    test('schema version is 7', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      // v7 is 14-01's alarm_history change (the alarm(uid) FK dropped,
      // rule_index / ts_source / deactivated_reason added, partial unique
      // index). This literal is the pin that makes a version bump a deliberate
      // edit rather than a side effect.
      expect(db.schemaVersion, 7);
    });

    test('seeds exactly four roles', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final rows = await db.customSelect('SELECT * FROM app_role').get();
      expect(rows, hasLength(4));
    });

    test('the four roles are the spec\'s four, all marked seeded', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final rows = await db.customSelect('SELECT * FROM app_role').get();
      expect(
        rows.map((r) => r.read<String>('name')).toSet(),
        {'Operator', 'Shift Leader', 'Maintenance', 'Engineering'},
      );
      for (final r in rows) {
        // SQLite has no boolean type; drift stores it as 0/1.
        expect(r.read<bool>('seeded'), isTrue,
            reason: '${r.read<String>('name')} should be marked seeded');
      }
    });

    test('seeded group sets match the spec exactly', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final roles = await _roles(db);

      // Exact sets, not supersets: widening a seed role has to fail here.
      expect(roles['Operator'], {AccessGroup.operate});
      expect(roles['Shift Leader'], {
        AccessGroup.operate,
        AccessGroup.setpoints,
      });
      expect(roles['Maintenance'], {
        AccessGroup.operate,
        AccessGroup.setpoints,
        AccessGroup.device,
        AccessGroup.force,
      });
      expect(roles['Engineering'], AccessGroup.values.toSet());
      expect(roles['Engineering'], hasLength(7));
    });

    test('creates the three audit_entry indexes', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final indexes = await _indexNames(db);
      for (final index in _auditIndexes) {
        expect(indexes, contains(index),
            reason: 'audit index "$index" should exist on a fresh install');
      }
    });
  });

  group('v5 -> v6 upgrade', () {
    // A temp *file* database rather than an in-memory one, because the upgrade
    // has to survive a close and a reopen: `NativeDatabase.memory()` hands out
    // a new empty database on every open, so there would be nothing to upgrade.
    //
    // The v5 state is reconstructed by creating the current schema, dropping
    // what v6 added and rewinding `user_version` — rather than by checking in a
    // v5 database file, which would rot the first time an unrelated table
    // changed.
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tfc_access_schema_test');
      dbFile = File('${tempDir.path}/app.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// Builds a database at v5: the v6 tables and indexes removed, and
    /// `user_version` rewound so the next open runs `onUpgrade(5, 6)`.
    Future<void> makeV5Database() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();

      // A row that must survive the upgrade.
      await db.customStatement(
        "INSERT INTO alarm (uid, title, description, rules) "
        "VALUES ('pre-v6', 'CN04 jam', 'Belt CN04 jammed', '[]')",
      );

      for (final index in _auditIndexes) {
        await db.customStatement('DROP INDEX $index');
      }
      // audit_entry first, then app_user, then app_role: app_user references
      // app_role.
      await db.customStatement('DROP TABLE audit_entry');
      await db.customStatement('DROP TABLE app_user');
      await db.customStatement('DROP TABLE app_role');
      for (final stmt in _v7Rollback) {
        await db.customStatement(stmt);
      }
      await db.customStatement('PRAGMA user_version = 5');
      await db.close();
    }

    /// Reopens the same file, forcing the migration to run.
    Future<AppDatabase> reopen() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();
      return db;
    }

    test('gains the three tables', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final tables = await _tableNames(db);
      for (final table in _accessTables) {
        expect(tables, contains(table),
            reason: 'access table "$table" should be created by the upgrade');
      }
    });

    test('keeps rows written before the upgrade', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final rows = await db
          .customSelect("SELECT * FROM alarm WHERE uid = 'pre-v6'")
          .get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('title'), 'CN04 jam');
    });

    test('seeds the four roles with the spec\'s group sets', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final roles = await _roles(db);
      expect(roles.keys.toSet(),
          {'Operator', 'Shift Leader', 'Maintenance', 'Engineering'});
      expect(roles['Operator'], {AccessGroup.operate});
      expect(roles['Engineering'], AccessGroup.values.toSet());
    });

    test('creates the three audit_entry indexes', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final indexes = await _indexNames(db);
      for (final index in _auditIndexes) {
        expect(indexes, contains(index),
            reason: 'audit index "$index" should be created by the upgrade');
      }
    });

    test('leaves schema version at the current version', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final row =
          await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), db.schemaVersion,
          reason: 'a v5 database opens straight to the current version — '
              'onUpgrade(5, N) runs every branch above 5 in one pass. Read '
              'off db.schemaVersion rather than written as a literal: the '
              'literal pin lives in "schema version is 7" above, and this arm '
              'is about the upgrade arriving THERE, not about which number '
              'there is');
    });
  });

  group('idempotency', () {
    // What a second SVN station opening the shared database does. The seed has
    // to be safe to run against rows that already exist — drop
    // `onConflict: DoNothing()` and this group goes red.
    test('re-seeding leaves app_role at four rows', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.seedAccessRolesForTest();
      await db.seedAccessRolesForTest();

      final rows = await db.customSelect('SELECT * FROM app_role').get();
      expect(rows, hasLength(4));
    });

    test('re-seeding does not reset an edited role', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      // Somebody ticks `setpoints` on Operator at commissioning.
      await db.customStatement(
        "UPDATE app_role SET groups = '[\"operate\",\"setpoints\"]' "
        "WHERE name = 'Operator'",
      );
      await db.seedAccessRolesForTest();

      final roles = await _roles(db);
      expect(roles['Operator'], {AccessGroup.operate, AccessGroup.setpoints},
          reason: 'the seed must not overwrite an edited role');
    });

    test('the audit indexes survive a second migration run', () async {
      // `CREATE INDEX IF NOT EXISTS`, so running the statements again is a
      // no-op rather than an error.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      for (final index in _auditIndexes) {
        await db.customStatement(
          'CREATE INDEX IF NOT EXISTS $index ON audit_entry (at DESC)',
        );
      }

      final indexes = await _indexNames(db);
      for (final index in _auditIndexes) {
        expect(indexes, contains(index));
      }
    });
  });

  group('constraints', () {
    test('app_user.role_name is a declared foreign key to app_role', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      // Assert the constraint is *declared*, separately from whether SQLite is
      // configured to enforce it — `PRAGMA foreign_keys` is per-connection and
      // off by default, so a schema check is the durable assertion.
      final row = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='app_user'",
          )
          .getSingle();
      final sql = row.read<String>('sql');
      expect(sql, contains('REFERENCES app_role'));
    });

    test('an app_user with an unknown role is rejected when FKs are on',
        () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();
      await db.customStatement('PRAGMA foreign_keys = ON');

      expect(
        () => db.customStatement(
          "INSERT INTO app_user "
          "(username, role_name, password_hash, salt, created_at) "
          "VALUES ('jon', 'Not A Role', 'hash', 'salt', '2026-08-28T00:00:00Z')",
        ),
        // Message-matched, not just `isA<Exception>()`: a typo'd column name
        // would also throw, and would pass a bare type check.
        throwsA(
          isA<Object>().having(
            (e) => e.toString().toUpperCase(),
            'message',
            contains('FOREIGN KEY'),
          ),
        ),
      );
    });

    test('an app_user with a seeded role is accepted', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();
      await db.customStatement('PRAGMA foreign_keys = ON');

      await db.customStatement(
        "INSERT INTO app_user "
        "(username, role_name, password_hash, salt, created_at) "
        "VALUES ('jon', 'Engineering', 'hash', 'salt', '2026-08-28T00:00:00Z')",
      );

      final rows = await db.customSelect('SELECT * FROM app_user').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('role_name'), 'Engineering');
    });

    test('audit_entry.origin defaults to operator', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      // Only the non-nullable columns, `origin` deliberately omitted: an
      // unmarked caller must land in the trail as a hand-made write rather
      // than escaping it.
      await db.customStatement(
        "INSERT INTO audit_entry "
        "(at, who, station, role_name, surface, item_key, group_required, allowed, action_id) "
        "VALUES ('2026-08-28T00:00:00Z', 'jon', 'SVN-NES-OT-CL02', 'Engineering', "
        "'tag', 'CN04.DEV01.SUB01', 'device', 1, 'act-1')",
      );

      final rows = await db.customSelect('SELECT * FROM audit_entry').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('origin'), 'operator');
      expect(rows.first.read<String?>('member'), isNull);
      expect(rows.first.read<String?>('reason'), isNull);
    });

    test('a denial is storable', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.customStatement(
        "INSERT INTO audit_entry "
        "(at, who, station, role_name, surface, item_key, group_required, allowed, action_id) "
        "VALUES ('2026-08-28T00:00:00Z', 'anonymous', 'SVN-NES-OT-CL02', 'Operator', "
        "'tag', 'CN04.DEV01.SUB01', 'force', 0, 'act-2')",
      );

      final rows = await db.customSelect('SELECT * FROM audit_entry').get();
      expect(rows.first.read<bool>('allowed'), isFalse);
    });
  });
}

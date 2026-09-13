// Schema v6/v7 — the access control tables, their migrations and their seed.
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

/// Undoes what schema **v8** added to `alarm_history`.
///
/// The old-version fixtures in this repository are built by creating the
/// CURRENT schema and removing what came later, so every future version has to
/// add its own rollback here or the fixture is not the shape it claims to be.
/// Without these, the SQLite arm of `onUpgrade(5, 8)` — and of
/// `onUpgrade(6, 8)` — aborts on `duplicate column name: rule_index`. That is
/// the fixture, not the migration: `alarm_history` is created once, in
/// `onCreate`, and no upgrade arm re-creates it, so a real pre-v8 database has
/// none of these columns and the unguarded `ADD COLUMN` is correct.
///
/// The index goes first. SQLite refuses to drop a column an index refers to.
const _v8Rollback = [
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
    test('schema version is 8', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      // v8 is 14-01's alarm_history change (the alarm(uid) FK dropped,
      // rule_index / ts_source / deactivated_reason added, partial unique
      // index). This literal is the pin that makes a version bump a deliberate
      // edit rather than a side effect.
      expect(db.schemaVersion, 8);
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
      for (final stmt in _v8Rollback) {
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
              'literal pin lives in "schema version is 8" above, and this arm '
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

  // The page-visibility whitelist columns. See
  // `docs/page-visibility-whitelist-design.md` §2. The Postgres arm of this
  // branch is two `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements and is
  // no more exercised here than the v6 Postgres DDL is; `_columnNames` below
  // is what stands behind the SQLite side.
  group('v6 -> v7 upgrade', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tfc_v7_schema_test');
      dbFile = File('${tempDir.path}/app.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<Set<String>> columnNames(GeneratedDatabase db, String table) async {
      final rows = await db.customSelect('PRAGMA table_info($table)').get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    /// Builds a database at v6: both `allowed_pages` columns dropped and
    /// `user_version` rewound, so the next open runs `onUpgrade(6, 7)`.
    Future<void> makeV6Database() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();

      // An account that predates the column — the row whose behaviour must not
      // change across the upgrade.
      await db.customStatement(
        "INSERT INTO app_user "
        "(username, role_name, password_hash, salt, created_at, station_account) "
        "VALUES ('jon', 'Engineering', 'hash', 'salt', '2026-09-01T00:00:00Z', 0)",
      );

      await db.customStatement('ALTER TABLE app_role DROP COLUMN allowed_pages');
      await db.customStatement('ALTER TABLE app_user DROP COLUMN allowed_pages');
      // v8 is above 6 as well, so the fixture has to shed it too — see
      // `_v8Rollback`.
      for (final stmt in _v8Rollback) {
        await db.customStatement(stmt);
      }
      await db.customStatement('PRAGMA user_version = 6');
      await db.close();
    }

    Future<AppDatabase> reopen() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();
      return db;
    }

    test('adds allowed_pages to app_role and app_user', () async {
      await makeV6Database();
      final db = await reopen();
      addTearDown(() => db.close());

      expect(await columnNames(db, 'app_role'), contains('allowed_pages'));
      expect(await columnNames(db, 'app_user'), contains('allowed_pages'));
    });

    test('every carried-over row upgrades to NULL, not to a whitelist',
        () async {
      // The whole behaviour-preserving claim. A seeded role landing on '[]'
      // would blank every page on the floor at upgrade; an account landing on
      // '[]' or on a populated array would mint a personal exemption that no
      // later role whitelist could bind.
      await makeV6Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final roles = await db.customSelect('SELECT * FROM app_role').get();
      expect(roles, hasLength(4));
      for (final row in roles) {
        expect(row.read<String?>('allowed_pages'), isNull,
            reason: '${row.read<String>('name')} must carry over unrestricted');
      }

      final users = await db.customSelect('SELECT * FROM app_user').get();
      expect(users, hasLength(1));
      expect(users.first.read<String?>('allowed_pages'), isNull,
          reason: 'a v6 account follows its role, and NULL is how that is '
              'spelled — it is not "sees every page"');
    });

    test('leaves schema version at the current version', () async {
      await makeV6Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final row = await db.customSelect('PRAGMA user_version').getSingle();
      // Read off the database rather than pinned: the alarm change from
      // 14-01 took v8 when the two branches collided, so a v6 or v5
      // database now opens straight through the whitelist arm and on to
      // 8. The literal pin lives in 'schema version is 8'; this arm is
      // about the upgrade arriving THERE.
      expect(row.read<int>('user_version'), db.schemaVersion);
    });

    test('a v5 database reaches the current version in one open, with both columns',
        () async {
      // The `from < 6` arm creates the tables from the current definitions,
      // which already carry the column — so the `from < 7` arm must NOT try to
      // add it again. This is the case the `from >= 6` guard exists for; drop
      // it and SQLite throws "duplicate column name" here.
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();
      await db.customStatement('DROP TABLE audit_entry');
      await db.customStatement('DROP TABLE app_user');
      await db.customStatement('DROP TABLE app_role');
      for (final stmt in _v8Rollback) {
        await db.customStatement(stmt);
      }
      await db.customStatement('PRAGMA user_version = 5');
      await db.close();

      final upgraded = await reopen();
      addTearDown(() => upgraded.close());

      expect(await columnNames(upgraded, 'app_role'),
          contains('allowed_pages'));
      expect(await columnNames(upgraded, 'app_user'),
          contains('allowed_pages'));
      final row =
          await upgraded.customSelect('PRAGMA user_version').getSingle();
      // Read off the database rather than pinned: the alarm change from
      // 14-01 took v8 when the two branches collided, so a v6 or v5
      // database now opens straight through the whitelist arm and on to
      // 8. The literal pin lives in 'schema version is 8'; this arm is
      // about the upgrade arriving THERE.
      expect(row.read<int>('user_version'), db.schemaVersion);
    });
  });

  group('the Postgres DDL names the same columns as the tables', () {
    // Source-derived parity, the only thing standing behind the raw Postgres
    // statements — no test connects to a server. It reads the migration source
    // and asserts every `allowed_pages` mention a reader would expect is
    // there, in both the v6 CREATE TABLE literals (a fresh Postgres install
    // runs those) and the v7 ALTER statements (an upgraded one runs these).
    late String source;

    setUpAll(() {
      source = File('lib/core/database_drift.dart').readAsStringSync();
    });

    test('the v6 CREATE TABLE literals carry allowed_pages', () {
      expect(
        source,
        contains('CREATE TABLE IF NOT EXISTS app_role (name TEXT PRIMARY KEY, '
            'groups TEXT NOT NULL, seeded BOOLEAN NOT NULL DEFAULT FALSE, '
            'allowed_pages TEXT)'),
      );
      expect(source, contains('station_account BOOLEAN NOT NULL DEFAULT FALSE, '
          'allowed_pages TEXT)'));
    });

    test('the v7 arm alters both tables idempotently', () {
      // IF NOT EXISTS is not decoration: several SVN stations share one
      // Postgres database and each of them runs this branch when it opens.
      expect(
        source,
        contains('ALTER TABLE app_role ADD COLUMN IF NOT EXISTS '
            'allowed_pages TEXT'),
      );
      expect(
        source,
        contains('ALTER TABLE app_user ADD COLUMN IF NOT EXISTS '
            'allowed_pages TEXT'),
      );
    });
  });
}

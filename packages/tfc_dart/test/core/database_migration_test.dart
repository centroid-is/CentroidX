import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart' show AppDatabase;

/// Returns the set of user table names in the given [db].
Future<Set<String>> _tableNames(GeneratedDatabase db) async {
  final rows = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
  ).get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// All MCP tables added in the v4→v5 migration.
const _mcpTables = [
  'audit_log',
  'plc_code_block',
  'plc_variable',
  'drawing',
  'drawing_component',
  'tech_doc',
  'tech_doc_section',
  'mcp_proposal',
  'plc_var_ref',
  'plc_fb_instance',
  'plc_block_call',
];

/// The access control tables added in the v5→v6 migration.
const _accessTables = [
  'app_role',
  'app_user',
  'audit_entry',
];

/// The relational configuration tables added in the v10 migration.
const _configTables = [
  'config_item',
  'config_change',
];

/// The indexes that go up with them, in the same arm.
const _configIndexes = [
  'idx_config_item_scope_kind',
  'idx_config_change_entity',
  'idx_config_change_action',
  'idx_config_change_at',
];

/// Returns the set of named index names in the given [db].
Future<Set<String>> _indexNames(GeneratedDatabase db) async {
  final rows = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'",
  ).get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// The `CREATE TABLE` text SQLite itself recorded for [table] — what the
/// engine stored, not what drift meant to say.
Future<String> _sqliteDdl(GeneratedDatabase db, String table) async {
  final rows = await db.customSelect(
    "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
    variables: [Variable<String>(table)],
  ).get();
  expect(rows, hasLength(1), reason: 'no `$table` table to read DDL from');
  return rows.first.read<String>('sql');
}

/// The v9 `config_change` NOTIFY statements as the database would receive
/// them, joined for matching.
///
/// The arm that runs them is Postgres-only and nothing in this package can
/// execute it — the gap the v6, v7 and v8 Postgres arms record about themselves.
/// So what is left to assert is the text, and it is asserted against the
/// runtime strings rather than the source, which carries Dart's escaping.
String _notifyStatements() =>
    AppDatabase.configChangeNotifyStatementsForTest.join('\n');

/// Undoes the v10 arm on an already-created database, leaving it shaped like a
/// v7 one so the arm can then be run against it for real.
///
/// Dropping is how a v7 database is reached from here: `inMemoryForTest`
/// creates at the current schema version, so there is no other way to an older
/// shape short of hand-writing the whole of v7.
Future<void> _dropConfigSchema(GeneratedDatabase db) async {
  for (final index in _configIndexes) {
    await db.customStatement('DROP INDEX IF EXISTS $index');
  }
  for (final table in _configTables) {
    await db.customStatement('DROP TABLE IF EXISTS $table');
  }
}

void main() {
  group('AppDatabase migration', () {
    test('fresh install creates all MCP tables', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());

      // Force schema creation
      await db.customSelect('SELECT 1').getSingle();

      final tables = await _tableNames(db);
      for (final table in _mcpTables) {
        expect(tables, contains(table),
            reason: 'MCP table "$table" should exist on fresh install');
      }
      // Also check pre-existing tables
      expect(tables, contains('alarm'));
      expect(tables, contains('alarm_history'));
      expect(tables, contains('flutter_preferences'));
      // Access control tables, added in the v5→v6 migration. Covered in depth
      // by access_schema_test.dart; asserted here so the two files agree on
      // what a fresh install contains.
      for (final table in _accessTables) {
        expect(tables, contains(table),
            reason: 'access table "$table" should exist on fresh install');
      }
    });

    test('schema version is 14', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      // 14 is `alarm_history` becoming writable: the `alarm(uid)` foreign key
      // dropped, `rule_index` / `ts_source` / `deactivated_reason` added, and
      // the partial unique index that makes two OPEN rows for one alarm-rule
      // unrepresentable. This literal is the pin that makes a version bump a
      // deliberate edit rather than a side effect.
      expect(db.schemaVersion, 14);
    });

    test('fresh install creates the config tables and their indexes',
        () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final tables = await _tableNames(db);
      for (final table in _configTables) {
        expect(tables, contains(table),
            reason: 'config table "$table" should exist on fresh install');
      }

      // The indexes come from `_createConfigIndexes`, called by `onCreate` as
      // well as by the arm — a fresh install never runs the arm, so without
      // that call a new station would read `config_item` by table scan.
      final indexes = await _indexNames(db);
      for (final index in _configIndexes) {
        expect(indexes, contains(index),
            reason: 'config index "$index" should exist on fresh install');
      }
    });

    test('the SQLite config tables carry no CHECK on scope', () async {
      // The invariant, from the side that is easy to break by accident.
      // `CHECK (scope = 'shared')` belongs on the Postgres tables only: the
      // local database is where `station:<hostname>` rows live, and the same
      // constraint here would reject every row this milestone writes.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      for (final table in _configTables) {
        final ddl = await _sqliteDdl(db, table);
        expect(ddl.toUpperCase().contains('CHECK'), isFalse,
            reason: 'the SQLite `$table` must not constrain `scope`. Station '
                'rows are the only rows a local database will ever hold, so a '
                "CHECK (scope = 'shared') here rejects all of them. It is the "
                'Postgres DDL that carries it, and only that one.');
      }
    });

    test('a v9 database upgrades to v10, twice over', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _dropConfigSchema(db);
      expect(await _tableNames(db), isNot(contains('config_item')),
          reason: 'the teardown must actually reach a v9 shape, or the arm '
              'below would be asserted against a database that already has '
              'everything it creates');

      await db.migration.onUpgrade(Migrator(db), 9, 10);

      var tables = await _tableNames(db);
      var indexes = await _indexNames(db);
      for (final table in _configTables) {
        expect(tables, contains(table),
            reason: 'the v10 arm must create $table');
      }
      for (final index in _configIndexes) {
        expect(indexes, contains(index),
            reason: 'the v10 arm must create $index');
      }

      // Several SVN stations share one database and each of them runs the arm
      // when it opens, so the second one through must be a no-op rather than
      // an abort that leaves the database half-upgraded. Asserted on SQLite
      // because that is the arm a test can execute — drift's `createTable`
      // emits `CREATE TABLE IF NOT EXISTS` too. The Postgres arm's
      // idempotency rests on its own `IF NOT EXISTS` literals and is
      // unexercised here, exactly as that arm's comment says.
      await db.migration.onUpgrade(Migrator(db), 9, 10);

      tables = await _tableNames(db);
      indexes = await _indexNames(db);
      for (final table in _configTables) {
        expect(tables, contains(table));
      }
      for (final index in _configIndexes) {
        expect(indexes, contains(index));
      }
    });

    test('the v12 arm creates the paging index on a database stamped 11',
        () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();
      await db.customStatement('DROP INDEX IF EXISTS idx_config_change_at');
      expect(await _indexNames(db), isNot(contains('idx_config_change_at')));

      await db.migration.onUpgrade(Migrator(db), 11, 12);
      await db.migration.onUpgrade(Migrator(db), 11, 12);

      expect(await _indexNames(db), contains('idx_config_change_at'),
          reason: 'an index added to the list after v11 stamped a database '
              'reaches it only through an arm of its own');
    });

    test('the v11 arm is a no-op on SQLite, run twice over', () async {
      // The whole content of v11 is a Postgres trigger, so on SQLite there is
      // nothing to create and nothing to find afterwards. What this pins is
      // that the arm *runs* here without throwing: an `if (native)` written
      // the wrong way round, or a `customStatement` outside the dialect
      // guard, would send `CREATE TRIGGER … EXECUTE FUNCTION` to SQLite and
      // fail every local database's open — which on a station is not a failed
      // migration, it is an HMI that will not start.
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final before = await _tableNames(db);
      await db.migration.onUpgrade(Migrator(db), 10, 11);
      await db.migration.onUpgrade(Migrator(db), 10, 11);

      expect(await _tableNames(db), before,
          reason: 'the v11 arm must add nothing to a SQLite database');
    });

    test('the v11 NOTIFY trigger carries a constant empty payload', () async {
      // The one property of this trigger that must never drift. `pg_notify`
      // does not truncate an oversized payload, it errors the statement that
      // fired it — so a trigger that carried the changed row, or the changed
      // key, would eventually fail the very save it was reporting. A constant
      // payload also collapses to one delivery per transaction, which is what
      // "one NOTIFY per action" is made of.
      final source = _notifyStatements();

      expect(source, contains("pg_notify('config_change', '')"),
          reason: 'the payload must stay the empty string. Carrying the key '
              'in it is what the retired keyed-notification trigger did, and '
              'it is the wrong primitive here: N keys in one save become N '
              'payloads and N deliveries, and a large one errors the save.');
      expect(source.contains('json_build_object'), isFalse,
          reason: 'a payload built from the row is the 8000-byte hazard this '
              'trigger exists to avoid');
    });

    test('the v11 trigger is statement-level, insert-only and re-runnable',
        () async {
      final source = _notifyStatements();

      expect(source, contains('AFTER INSERT ON config_change'),
          reason: 'config_change is append-only; there is no UPDATE or '
              'DELETE to notify about');
      expect(source, contains('FOR EACH STATEMENT'),
          reason: 'with a constant payload a row-level trigger does the same '
              'work once per row instead of once per statement');
      expect(source, contains('DROP TRIGGER IF EXISTS config_change_notify'),
          reason: 'several SVN stations share one database and each of them '
              'runs this arm when it opens, so it has to be safe twice');
      expect(source, contains('CREATE OR REPLACE FUNCTION'),
          reason: 'same reason as the DROP: the second station through must '
              'not abort the migration half-way');
    });

    test('MCP tables support basic CRUD operations', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      // Insert into audit_log
      await db.customStatement(
        "INSERT INTO audit_log (operator_id, tool, arguments, status, created_at) "
        "VALUES ('test-op', 'test-tool', '{}', 'success', '2026-03-11T00:00:00Z')",
      );

      final rows = await db.customSelect('SELECT * FROM audit_log').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('operator_id'), 'test-op');

      // Insert into plc_code_block and plc_variable (FK relationship)
      await db.customStatement(
        "INSERT INTO plc_code_block (asset_key, block_name, block_type, file_path, declaration, full_source, indexed_at) "
        "VALUES ('pump3', 'FB_Pump3', 'FUNCTION_BLOCK', '/plc/pump3.st', 'VAR END_VAR', 'FUNCTION_BLOCK FB_Pump3 END_FUNCTION_BLOCK', '2026-03-11T00:00:00Z')",
      );
      await db.customStatement(
        "INSERT INTO plc_variable (block_id, variable_name, variable_type, section, qualified_name) "
        "VALUES (1, 'speed', 'REAL', 'VAR_INPUT', 'FB_Pump3.speed')",
      );

      final vars =
          await db.customSelect('SELECT * FROM plc_variable').get();
      expect(vars, hasLength(1));
      expect(vars.first.read<String>('variable_name'), 'speed');
    });

    test('drawing and drawing_component FK relationship works', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.customStatement(
        "INSERT INTO drawing (asset_key, drawing_name, file_path, page_count, uploaded_at) "
        "VALUES ('pump3', 'Pump3_Wiring', '/drawings/pump3.pdf', 2, '2026-03-11T00:00:00Z')",
      );
      await db.customStatement(
        "INSERT INTO drawing_component (drawing_id, page_number, full_page_text) "
        "VALUES (1, 1, 'Page 1 text content')",
      );

      final components =
          await db.customSelect('SELECT * FROM drawing_component').get();
      expect(components, hasLength(1));
      expect(components.first.read<int>('drawing_id'), 1);
    });

    test('tech_doc and tech_doc_section FK relationship works', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.customStatement(
        "INSERT INTO tech_doc (name, pdf_bytes, page_count, section_count, uploaded_at) "
        "VALUES ('ATV320 Manual', X'00', 100, 10, '2026-03-11T00:00:00Z')",
      );
      await db.customStatement(
        "INSERT INTO tech_doc_section (doc_id, title, content, page_start, page_end, level, sort_order) "
        "VALUES (1, 'Introduction', 'Overview of the ATV320 drive', 1, 5, 1, 1)",
      );

      final sections =
          await db.customSelect('SELECT * FROM tech_doc_section').get();
      expect(sections, hasLength(1));
      expect(sections.first.read<String>('title'), 'Introduction');
    });
  });

  // The config-store arm's bound, exercised through a real open rather than
  // by calling `onUpgrade` by hand: what is being pinned is which arms a
  // stamped `user_version` reaches, and only drift deciding that for itself
  // is evidence of it.
  //
  // In-memory will not do here. `inMemoryForTest` creates at the current
  // version and the database dies with the connection, so there is no way to
  // stamp a number and come back to it; a file is the only fixture that
  // survives a close.
  group('the config-store arm reaches a database stamped by another line',
      () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tfc_config_arm_test');
      dbFile = File('${tempDir.path}/app.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<AppDatabase> open() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      // Forces the migration; drift does nothing until the first query.
      await db.customSelect('SELECT 1').getSingle();
      return db;
    }

    Future<int> userVersion(GeneratedDatabase db) async =>
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');

    test('a database stamped 10 with no config tables heals on the next open',
        () async {
      // The station at 10.104.60.84, in a temp directory. A pre-merge build
      // of the relay branch stamped `user_version` 10 for an arm of its own,
      // so the database claims to have passed v10 and has never run the arm
      // that creates these tables. With the bound at `from < 10` it never
      // will: the arm is skipped, the v12 index arm then runs
      // `CREATE INDEX ... ON config_item` against a table that is not there,
      // and the open fails outright.
      //
      // This is the test that fails against a `from < 10` arm. If it is ever
      // narrowed back, this is what says so.
      final db = await open();
      await _dropConfigSchema(db);
      expect(await _tableNames(db), isNot(contains('config_item')),
          reason: 'the fixture must actually reach a shape without the '
              'config tables, or the assertions below are vacuous');
      await db.customStatement('PRAGMA user_version = 10');
      await db.close();

      final upgraded = await open();
      addTearDown(() => upgraded.close());

      final tables = await _tableNames(upgraded);
      for (final table in _configTables) {
        expect(tables, contains(table),
            reason: 'a database stamped 10 by another line has never run the '
                'config arm, so the widened bound has to reach it');
      }
      final indexes = await _indexNames(upgraded);
      for (final index in _configIndexes) {
        expect(indexes, contains(index));
      }
      expect(await userVersion(upgraded), upgraded.schemaVersion);
    });

    test('a station already at 12 upgrades to 13 as a no-op, rows intact',
        () async {
      // The other half, and the one that says bumping the number is safe for
      // every station on main: they are all at 12 with both tables full. The
      // widened arm runs over them and must create nothing and touch no row —
      // `createTable` is `CREATE TABLE IF NOT EXISTS` and every index
      // statement is `CREATE INDEX IF NOT EXISTS`.
      final db = await open();
      await db.customStatement(
        "INSERT INTO config_item "
        "(kind, id, scope, payload, rev, updated_at, updated_by) "
        "VALUES ('page', 'overview', 'shared', '{\"a\":1}', 3, "
        "'2026-09-01T00:00:00Z', 'jon')",
      );
      await db.customStatement('PRAGMA user_version = 12');
      await db.close();

      final upgraded = await open();
      addTearDown(() => upgraded.close());

      expect(await userVersion(upgraded), upgraded.schemaVersion,
          reason: 'the stamp has to move off 12, or the arm did not run');
      final rows =
          await upgraded.customSelect('SELECT * FROM config_item').get();
      expect(rows, hasLength(1),
          reason: 'the arm must not drop or re-create a populated table');
      expect(rows.first.read<String>('payload'), '{"a":1}');
      expect(rows.first.read<int>('rev'), 3);
      expect(await _tableNames(upgraded), containsAll(_configTables));
      expect(await _indexNames(upgraded), containsAll(_configIndexes));
    });
  });
}

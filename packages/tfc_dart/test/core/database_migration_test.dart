import 'package:drift/drift.dart';
import 'package:test/test.dart';
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

/// The relational configuration tables added in the v6→v7 migration.
const _configTables = [
  'config_item',
  'config_change',
];

/// The indexes that go up with them, in the same arm.
const _configIndexes = [
  'idx_config_item_scope_kind',
  'idx_config_change_entity',
  'idx_config_change_action',
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

/// Undoes the v7 arm on an already-created database, leaving it shaped like a
/// v6 one so the arm can then be run against it for real.
///
/// Dropping is how a v6 database is reached from here: `inMemoryForTest`
/// creates at the current schema version, so there is no other way to an older
/// shape short of hand-writing the whole of v6.
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
    test('fresh install (v7) creates all MCP tables', () async {
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

    test('schema version is 7', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      expect(db.schemaVersion, 7);
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

    test('a v6 database upgrades to v7, twice over', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await _dropConfigSchema(db);
      expect(await _tableNames(db), isNot(contains('config_item')),
          reason: 'the teardown must actually reach a v6 shape, or the arm '
              'below would be asserted against a database that already has '
              'everything it creates');

      await db.migration.onUpgrade(Migrator(db), 6, 7);

      var tables = await _tableNames(db);
      var indexes = await _indexNames(db);
      for (final table in _configTables) {
        expect(tables, contains(table),
            reason: 'the v7 arm must create $table');
      }
      for (final index in _configIndexes) {
        expect(indexes, contains(index),
            reason: 'the v7 arm must create $index');
      }

      // Several SVN stations share one database and each of them runs the arm
      // when it opens, so the second one through must be a no-op rather than
      // an abort that leaves the database half-upgraded. Asserted on SQLite
      // because that is the arm a test can execute — drift's `createTable`
      // emits `CREATE TABLE IF NOT EXISTS` too. The Postgres arm's
      // idempotency rests on its own `IF NOT EXISTS` literals and is
      // unexercised here, exactly as that arm's comment says.
      await db.migration.onUpgrade(Migrator(db), 6, 7);

      tables = await _tableNames(db);
      indexes = await _indexNames(db);
      for (final table in _configTables) {
        expect(tables, contains(table));
      }
      for (final index in _configIndexes) {
        expect(indexes, contains(index));
      }
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
}

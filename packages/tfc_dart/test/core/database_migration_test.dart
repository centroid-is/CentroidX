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

void main() {
  group('AppDatabase migration', () {
    test('fresh install (v6) creates all MCP tables', () async {
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

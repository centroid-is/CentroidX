// Schema v7 — `access_template`, `access_key_binding` and the migration that
// creates them.
//
// **SQLite only, and that is a coverage statement rather than a scoping one.**
// An in-memory or temp-file `NativeDatabase` is the only backend a test in
// `test/core/` can open, so everything below exercises the `native` arm of the
// `from < 7` branch. What is therefore *not* covered here:
//
// - the Postgres arm's raw `CREATE TABLE IF NOT EXISTS` DDL for both tables —
//   no test in this package executes it, exactly as Phase 1's
//   `deferred-items.md` §1 recorded on 2026-08-28 for the `from < 6` arm,
//   which is still uncovered today;
// - the `CREATE INDEX IF NOT EXISTS` on Postgres, same reason;
// - two stations running the branch against one shared database, which is the
//   deployment the `IF NOT EXISTS` spelling exists for.
//
// `access_key_binding_table_test.dart` holds the source-derived column-parity
// tests that stand in for the missing execution, and says in its own reason
// strings what they do and do not prove.
//
// TODO(phase-4): the live-Postgres migration assertion belongs in
// `test/integration/database_integration_test.dart`, beside the one
// `access_schema_test.dart` has been asking for since Phase 1 — open a v6
// database, upgrade it, and assert `access_template` and `access_key_binding`
// exist with the binding index.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart' show DatabaseConfig;
import 'package:tfc_dart/core/database_drift.dart'
    show AppDatabase, AccessKeyBindingTableCompanion;

/// The set of user table names in [db].
Future<Set<String>> _tableNames(GeneratedDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// The set of index names in [db].
Future<Set<String>> _indexNames(GeneratedDatabase db) async {
  final rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

/// The two tables added by the v6→v7 migration, in one list because one
/// branch creates them: there is no state in which one exists and the other
/// does not.
const _v7Tables = ['access_template', 'access_key_binding'];

/// The `access_key_binding` index. `keysBoundTo` runs on every template delete
/// and on every render of the key repository's bound-key counts.
const _bindingIndex = 'idx_access_key_binding_template_name';

/// A rules JSON blob shaped like the one `AccessTemplate.encodeRules()`
/// produces: struct member -> `AccessGroup` name.
const _conveyorRules =
    '{"p_cmd_JogFwd":"operate","p_cfg_ManualFreq":"setpoints"}';

void main() {
  group('fresh install', () {
    test('creates access_template and access_key_binding', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final tables = await _tableNames(db);
      for (final table in _v7Tables) {
        expect(tables, contains(table),
            reason: 'v7 table "$table" should exist on a fresh install');
      }
    });

    test('schema version is at least 6', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      // Read off an open database rather than grepped out of the source: the
      // value the migrator actually compares `from` against. At least, not
      // exactly — these tables arrived in the `from < 6` arm, and the current
      // number belongs to `database_migration_test.dart`.
      expect(db.schemaVersion, greaterThanOrEqualTo(6));
    });

    test('creates the access_key_binding template_name index', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      final indexes = await _indexNames(db);
      expect(indexes, contains(_bindingIndex),
          reason: 'without it, every template delete and every bound-key count '
              'is a table scan of access_key_binding');
    });
  });

  group('rows', () {
    test('a template row survives a round trip verbatim', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.customStatement(
        'INSERT INTO access_template (name, rules, updated_at) '
        "VALUES ('conveyor', '$_conveyorRules', '2026-08-30T09:00:00.000')",
      );

      final rows = await db.customSelect('SELECT * FROM access_template').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('name'), 'conveyor');
      expect(rows.first.read<String>('rules'), _conveyorRules,
          reason: 'the rules column is opaque JSON — the database must not '
              'reinterpret what AccessTemplate.encodeRules wrote');
    });

    test('a binding row survives a round trip verbatim', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.customStatement(
        'INSERT INTO access_key_binding (key_name, template_name, updated_at) '
        "VALUES ('CN04.MOTOR01', 'conveyor', '2026-08-30T09:00:00.000')",
      );

      final rows =
          await db.customSelect('SELECT * FROM access_key_binding').get();
      expect(rows, hasLength(1));
      expect(rows.first.read<String>('key_name'), 'CN04.MOTOR01');
      expect(rows.first.read<String>('template_name'), 'conveyor');
    });

    test('a second binding for the same key replaces rather than duplicates',
        () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customSelect('SELECT 1').getSingle();

      await db.into(db.accessKeyBindingTable).insertOnConflictUpdate(
            AccessKeyBindingTableCompanion.insert(
              keyName: 'CN04.MOTOR01',
              templateName: 'conveyor',
              updatedAt: DateTime.utc(2026, 8, 30, 9),
            ),
          );
      await db.into(db.accessKeyBindingTable).insertOnConflictUpdate(
            AccessKeyBindingTableCompanion.insert(
              keyName: 'CN04.MOTOR01',
              templateName: 'conveyor-strict',
              updatedAt: DateTime.utc(2026, 8, 30, 10),
            ),
          );

      final rows =
          await db.customSelect('SELECT * FROM access_key_binding').get();
      expect(rows, hasLength(1),
          reason: 'key_name is the primary key, so "explicit, per key, always" '
              'is structural: a key cannot carry two answers');
      expect(rows.first.read<String>('template_name'), 'conveyor-strict');
    });

    test('template_name carries no foreign key to access_template', () async {
      final db = AppDatabase.inMemoryForTest();
      addTearDown(() => db.close());
      await db.customStatement('PRAGMA foreign_keys = ON');
      await db.customSelect('SELECT 1').getSingle();

      // Deliberate: 04-01's resolver treats a binding naming a missing
      // template as *unbound* and 04-08 surfaces it. A database-level
      // constraint would make a template delete fail with a driver error
      // instead of TemplateInUseException's named key list.
      await db.customStatement(
        'INSERT INTO access_key_binding (key_name, template_name, updated_at) '
        "VALUES ('CN04.MOTOR01', 'no-such-template', '2026-08-30T09:00:00.000')",
      );

      final rows =
          await db.customSelect('SELECT * FROM access_key_binding').get();
      expect(rows, hasLength(1),
          reason: 'a dangling binding must be storable — it is how a deleted '
              'template shows up as an unbound key rather than as an error');
    });
  });

  group('v5 -> v6 upgrade', () {
    // A temp *file* database, not an in-memory one: the upgrade has to survive
    // a close and a reopen, and `NativeDatabase.memory()` hands out a new empty
    // database every open. Same reconstruction trick as
    // `access_schema_test.dart` — build the current schema, drop what the
    // access milestone added and rewind `user_version`, rather than checking
    // in a v5 file that would rot the first time an unrelated table changed.
    //
    // **v5 is the only starting state there is.** These two tables arrived as
    // v7 during development and squash-merged into the single v6 arm, so no
    // database is ever at v6-without-templates; a suite simulating that state
    // would be testing a branch that cannot execute.
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('tfc_access_template_test');
      dbFile = File('${tempDir.path}/app.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// Builds a database at v5: every access table removed and `user_version`
    /// rewound, so the next open runs `onUpgrade(5, 6)`.
    Future<void> makeV5Database() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();

      // A row from the v5 world that must survive. Only an alarm: at v5 none
      // of the access tables exist, so nothing else can pre-date the upgrade.
      await db.customStatement(
        "INSERT INTO alarm (uid, title, description, rules) "
        "VALUES ('pre-v6', 'CN04 jam', 'Belt CN04 jammed', '[]')",
      );

      // Dropped in FK order — app_user references app_role — and without
      // explicit index drops, because SQLite takes a table's indexes with it.
      await db.customStatement('DROP TABLE access_key_binding');
      await db.customStatement('DROP TABLE access_template');
      await db.customStatement('DROP TABLE audit_entry');
      await db.customStatement('DROP TABLE app_user');
      await db.customStatement('DROP TABLE app_role');
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

    test('gains both tables', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final tables = await _tableNames(db);
      for (final table in _v7Tables) {
        expect(tables, contains(table),
            reason: 'table "$table" should be created by the upgrade');
      }
    });

    test('gains the binding index', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      expect(await _indexNames(db), contains(_bindingIndex));
    });

    test('both new tables are empty — the milestone ships no templates',
        () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      for (final table in _v7Tables) {
        final rows = await db.customSelect('SELECT * FROM $table').get();
        expect(rows, isEmpty,
            reason: '"$table" ships empty; the user creates the templates');
      }
    });

    test('keeps every pre-existing row', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final alarms = await db
          .customSelect("SELECT * FROM alarm WHERE uid = 'pre-v6'")
          .get();
      expect(alarms, hasLength(1));
      expect(alarms.first.read<String>('title'), 'CN04 jam');
    });

    // The roles are seeded by the same arm that creates `app_role`, so there
    // is no upgrade path on which a commissioned role could be reset — the
    // state that made "does not re-seed" a live risk cannot occur. What can
    // still happen is a second station opening a shared Postgres database and
    // running the seed against rows that exist; that idempotency is asserted
    // directly in `access_schema_test.dart` through `seedAccessRolesForTest`.

    test('leaves schema version at the current version', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), db.schemaVersion,
          reason: 'the reopen must stamp the version it migrated to, whatever '
              'that currently is — a v5 database runs every arm from 6 up');
    });
  });
}

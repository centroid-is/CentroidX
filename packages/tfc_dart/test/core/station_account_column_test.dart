/// `app_user.station_account` — the flag that lets a panel PC live signed
/// in as its area account.
///
/// A boolean on the USER, not the station: the freezer display's account
/// never expires anywhere, while a human signing in on the very same panel
/// keeps the inactivity window. Compare the device-local
/// `access.inactivity_timeout_disabled`, which is the station-wide blunt
/// instrument; this is the per-identity precise one.
///
/// Written RED first, against a schema without the column. It arrived
/// during development as a v8 `ADD COLUMN`; the milestone squash-merged as
/// one v6, so the column is now part of the shape `createTable` builds and
/// there is no ALTER left to test — what is left to test is that the shape
/// is right, on a fresh install and on the one upgrade path that exists.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:tfc_dart/core/database.dart';
import 'package:tfc_dart/core/database_drift.dart';

Future<List<String>> _userColumns(AppDatabase db) async {
  final rows =
      await db.customSelect("PRAGMA table_info('app_user')").get();
  return rows.map((r) => r.read<String>('name')).toList();
}

/// Undoes what schema **v7** added to `alarm_history`.
///
/// This file's v5 fixture is built by creating the CURRENT schema and removing
/// what came later, so every version after v6 has to add its own rollback here
/// or the fixture is not the shape it claims to be. Without these,
/// `onUpgrade(5, 7)`'s SQLite arm aborts on
/// `duplicate column name: rule_index` — the fixture, not the migration: a
/// real v5 SQLite database has none of these columns.
///
/// The index goes first. SQLite refuses to drop a column an index refers to.
const _v7Rollback = [
  'DROP INDEX IF EXISTS idx_alarm_history_open',
  'ALTER TABLE alarm_history DROP COLUMN rule_index',
  'ALTER TABLE alarm_history DROP COLUMN ts_source',
  'ALTER TABLE alarm_history DROP COLUMN deactivated_reason',
];

void main() {
  test('a fresh install carries station_account, defaulting false', () async {
    final db = AppDatabase.inMemoryForTest();
    addTearDown(() => db.close());
    await db.customSelect('SELECT 1').getSingle();

    expect(await _userColumns(db), contains('station_account'));

    await db.customStatement(
      "INSERT INTO app_user (username, role_name, password_hash, salt, "
      "created_at) VALUES ('jon', 'Engineering', 'x', 'y', '2026-09-02')",
    );
    final row = await db
        .customSelect(
            "SELECT station_account FROM app_user WHERE username = 'jon'")
        .getSingle();
    expect(row.read<bool>('station_account'), isFalse,
        reason: 'every existing account is a person until somebody says '
            'otherwise — the default must not mint immortal sessions');
  });

  test('schema version is 7', () async {
    final db = AppDatabase.inMemoryForTest();
    addTearDown(() => db.close());
    // v7 is 14-01's alarm_history change; station_account still arrives in the
    // v6 arm, which is what the rest of this file is about.
    expect(db.schemaVersion, 7);
  });

  group('upgrading a v5 database — the only upgrade path there is', () {
    late File dbFile;

    setUp(() async {
      dbFile = File(
          '${Directory.systemTemp.createTempSync('v6-mig').path}/db.sqlite');
    });

    tearDown(() {
      final dir = dbFile.parent;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// A database as v5 left it: no access tables at all, version rewound.
    ///
    /// The same simulation `access_schema_test.dart` uses, and the only
    /// starting state a real station can be in — every release build before
    /// this milestone is v5.
    Future<void> makeV5Database() async {
      final db = AppDatabase.forTest(
        DatabaseConfig(),
        NativeDatabase(dbFile, logStatements: false),
      );
      await db.customSelect('SELECT 1').getSingle();
      await db.customStatement('DROP TABLE access_key_binding');
      await db.customStatement('DROP TABLE access_template');
      await db.customStatement('DROP TABLE audit_entry');
      await db.customStatement('DROP TABLE app_user');
      await db.customStatement('DROP TABLE app_role');
      for (final stmt in _v7Rollback) {
        await db.customStatement(stmt);
      }
      await db.customStatement('PRAGMA user_version = 5');
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

    test('builds app_user with station_account, defaulting false', () async {
      await makeV5Database();
      final db = await reopen();
      addTearDown(() => db.close());

      expect(await _userColumns(db), contains('station_account'));

      await db.customStatement(
          "INSERT INTO app_user (username, role_name, password_hash, salt, "
          "created_at) VALUES ('omar', 'Engineering', 'x', 'y', '2026-09-01')");
      final row = await db
          .customSelect(
              "SELECT station_account FROM app_user WHERE username = 'omar'")
          .getSingle();
      expect(row.read<bool>('station_account'), isFalse,
          reason: 'an account is a person until somebody says otherwise — '
              'the default must not mint immortal sessions');
    });
  });
}

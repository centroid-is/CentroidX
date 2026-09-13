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

  test('schema version is at least 6', () async {
    final db = AppDatabase.inMemoryForTest();
    addTearDown(() => db.close());
    // `station_account` arrived in the `from < 6` arm. The current number is
    // asserted in `database_migration_test.dart`, not here.
    expect(db.schemaVersion, greaterThanOrEqualTo(6));
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

/// Two handles on one file have to be safe (SC-6).
///
/// `createDeviceLocalPreferences()` has five call sites and two of them run
/// inside methods called repeatedly, `bin/page_geometry.dart` reads the same
/// file out of process, and a dev box routinely has a second HMI running. A
/// singleton fixes the first of those and nothing fixes the other two, so the
/// file itself has to tolerate concurrent handles — which is what WAL and
/// `busy_timeout` are for, and neither is on by default in
/// `NativeDatabase.createInBackground`.
///
/// These tests run against real files on disk, deliberately: an in-memory
/// database has no journal mode worth asserting and cannot be opened twice.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_dart/core/database_drift.dart';

void main() {
  late Directory folder;
  final open = <AppDatabase>[];

  AppDatabase openLocal() {
    final db = AppDatabase.createLocal(folder);
    open.add(db);
    return db;
  }

  Future<String> pragma(AppDatabase db, String name) async {
    final row = await db.customSelect('PRAGMA $name;').getSingle();
    return row.data.values.first.toString();
  }

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('config_store_test');
  });

  tearDown(() async {
    // Every one of these owns a background isolate; leaking one leaks the
    // isolate for the rest of the run.
    for (final db in open) {
      await db.close();
    }
    open.clear();
    if (folder.existsSync()) {
      await folder.delete(recursive: true);
    }
  });

  test('creates config.sqlite in the folder it was given', () async {
    final db = openLocal();
    await db.customSelect('SELECT 1;').getSingle();

    expect(File('${folder.path}/config.sqlite').existsSync(), isTrue);
  });

  test('opens in WAL with a busy timeout', () async {
    final db = openLocal();

    expect(await pragma(db, 'journal_mode'), 'wal');
    expect(await pragma(db, 'busy_timeout'), '5000');
  });

  test('a second handle on the same file reads the first handle\'s write',
      () async {
    // drift warns about a second AppDatabase here. It is warning about two
    // instances sharing one QueryExecutor; these have one executor each, on
    // one file, which is the arrangement under test. Production uses a
    // singleton, so there the warning would mean a real mistake.
    final a = openLocal();
    final b = openLocal();

    await a.into(a.configItemTable).insert(
          ConfigItemTableCompanion.insert(
            kind: 'preference',
            id: 'startup_url',
            scope: 'station:test-host',
            payload: '{"type":"string","value":"/roe"}',
            updatedAt: DateTime.utc(2026, 9, 7, 12),
            updatedBy: 'test',
          ),
        );

    final rows = await b.select(b.configItemTable).get();

    expect(rows, hasLength(1));
    expect(rows.single.id, 'startup_url');
    expect(rows.single.payload, contains('/roe'));
    // The second handle went to the same file, not to a second one.
    expect(
      folder.listSync().map((e) => e.uri.pathSegments.last),
      contains('config.sqlite'),
    );
  });
}

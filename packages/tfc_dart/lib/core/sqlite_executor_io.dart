import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';

import 'sqlite_loader.dart';

/// An in-memory SQLite database. Tests only — see `AppDatabase.inMemoryForTest`.
QueryExecutor sqliteInMemory({bool logStatements = false}) =>
    NativeDatabase.memory(logStatements: logStatements);

/// A SQLite file opened on a background isolate.
QueryExecutor sqliteInBackground(File file, {bool logStatements = false}) =>
    NativeDatabase.createInBackground(file, logStatements: logStatements);

/// The device-local mirror's executor: [sqliteInBackground] plus the two
/// callbacks that only a native build can express.
///
/// It is here rather than at the call site because `setup` takes sqlite3's own
/// `Database`, which is FFI-bound — naming its type in `database_drift.dart`
/// is exactly the dependency this seam exists to cut, and it is what broke the
/// web build when `createLocal` arrived from main.
///
/// [isolateSetup] runs inside the background isolate before the file is
/// opened, which is the only place a library override can go; on the eLinux
/// stations it is what makes sqlite3 loadable at all.
QueryExecutor sqliteLocalMirror(File file, {bool logStatements = false}) =>
    NativeDatabase.createInBackground(
      file,
      logStatements: logStatements,
      isolateSetup: loadSqliteOnLinux,
      setup: (db) {
        // `createInBackground` does nothing about journal mode, and in the
        // default rollback journal a reader blocks a writer across processes
        // (`bin/page_geometry.dart` reads this file out-of-process). WAL is
        // durable in the file header, so setting it every open is a no-op —
        // except on a database restored from a rollback-mode backup, which it
        // repairs.
        db.execute('PRAGMA journal_mode = WAL;');
        // WAL still serialises writers. Without a timeout a concurrent write
        // returns SQLITE_BUSY immediately instead of waiting.
        db.execute('PRAGMA busy_timeout = 5000;');
      },
    );

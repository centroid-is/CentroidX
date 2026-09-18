import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';

import 'sqlite_loader.dart';

/// An in-memory database, for tests.
QueryExecutor sqliteInMemory({bool logStatements = false}) =>
    NativeDatabase.memory(logStatements: logStatements);

/// The station's own `db.sqlite`, opened on a background isolate.
QueryExecutor sqliteInBackground(File file, {bool logStatements = false}) =>
    NativeDatabase.createInBackground(file, logStatements: logStatements);

/// The device-local configuration store, `config.sqlite`.
///
/// Carries the two PRAGMAs and the library override that the plain background
/// opener does not, which is why it is a third entry point rather than a flag
/// on the second.
QueryExecutor sqliteLocalMirror(File file, {bool logStatements = false}) =>
    NativeDatabase.createInBackground(
      file,
      logStatements: logStatements,
      // Runs inside the background isolate before the file is opened, which is
      // the only place a library override can go. On the eLinux stations it is
      // what makes sqlite3 loadable at all — see [loadSqliteOnLinux].
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

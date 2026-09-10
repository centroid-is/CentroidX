import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;

Never _noLocalDatabase(String what) => throw UnsupportedError(
    'A browser has no local SQLite store, so $what cannot be opened here. '
    'A gateway panel reads and writes the plant through the relay socket; '
    'reaching this call means something took the direct-mode branch on a '
    'transport that has no database behind it.');

QueryExecutor sqliteInMemory({bool logStatements = false}) =>
    _noLocalDatabase('an in-memory database');

QueryExecutor sqliteInBackground(File file, {bool logStatements = false}) =>
    _noLocalDatabase('"${file.path}"');

/// Always false: there is no SQLite executor on this platform, so nothing can
/// be one. Callers use this to choose the local-file branch, and on the web
/// that branch is exactly what must not be taken.
bool isSqliteExecutor(QueryExecutor executor) => false;

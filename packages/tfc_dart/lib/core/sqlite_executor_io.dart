import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';

/// An in-memory SQLite database. Tests only — see `AppDatabase.inMemoryForTest`.
QueryExecutor sqliteInMemory({bool logStatements = false}) =>
    NativeDatabase.memory(logStatements: logStatements);

/// A SQLite file opened on a background isolate.
QueryExecutor sqliteInBackground(File file, {bool logStatements = false}) =>
    NativeDatabase.createInBackground(file, logStatements: logStatements);

/// Whether [executor] is the local SQLite one rather than Postgres.
///
/// A type test rather than a flag because the executor is built in several
/// places and a flag could disagree with the object.
bool isSqliteExecutor(QueryExecutor executor) => executor is NativeDatabase;

import 'dart:io';

import 'package:drift/drift.dart' show QueryExecutor;

Never _noLocalDatabase(String what) => throw UnsupportedError(
    'A browser has no local SQLite store, so $what cannot be opened here. '
    'Reaching this call means something took a branch that assumes a station '
    'filesystem. A web build renders configuration it was given; it does not '
    'keep its own copy of the plant.');

QueryExecutor sqliteInMemory({bool logStatements = false}) =>
    _noLocalDatabase('an in-memory database');

QueryExecutor sqliteInBackground(File file, {bool logStatements = false}) =>
    _noLocalDatabase('"${file.path}"');

QueryExecutor sqliteLocalMirror(File file, {bool logStatements = false}) =>
    _noLocalDatabase('the device-local mirror at "${file.path}"');

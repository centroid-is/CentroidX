/// Opening a local SQLite file, behind a compile-time seam.
///
/// `package:drift/drift.dart` is web-safe; `package:drift/native.dart` is not —
/// it reaches `sqlite3` and so `dart:ffi`, which dart2js refuses to compile at
/// all. Four call sites in `database_drift.dart` were the whole of that
/// dependency, and through them every screen that named a drift row type — the
/// audit trail, the access roster, the alarm editor — became unbuildable for
/// the browser.
///
/// So the four move here. Everything else in `database_drift.dart` (the table
/// definitions, the generated row classes, the query methods, and even the
/// Postgres path, which is pure Dart) compiles for the web unchanged.
///
/// The web arm throws. It is not a fallback to some browser-side database: a
/// gateway panel has no local store by design, and a call that reached here in
/// a browser would be a routing bug that should say so loudly rather than
/// quietly opening a second, divergent copy of the plant's configuration.
library;

export 'sqlite_executor_io.dart'
    if (dart.library.js_interop) 'sqlite_executor_web.dart';

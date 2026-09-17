/// Opening a local SQLite file, behind a compile-time seam.
///
/// `package:drift/drift.dart` is web-safe; `package:drift/native.dart` is not —
/// it reaches `package:sqlite3` and so `dart:ffi`, which dart2js refuses to
/// compile at all. Four call sites in `database_drift.dart` were the whole of
/// that dependency, and through them every screen that named a drift row
/// type — the audit trail, the access roster, the alarm editor — became
/// unbuildable for the browser. Everything else in `database_drift.dart` (the
/// table definitions, the generated row classes, the query methods, and even
/// the Postgres path, which is pure Dart) compiles for the web unchanged.
///
/// So the openers move here, and with them `sqlite_loader.dart` — the eLinux
/// `DynamicLibrary` override, which is `dart:ffi` by its nature and has no
/// browser meaning at all.
///
/// The web arm throws, and says which opener was reached. It is deliberately
/// not a fallback onto some browser-side database: a page rendered in a
/// browser has no local store, and quietly opening a second, divergent copy of
/// the plant's configuration is worse than the error.
library;

export 'sqlite_executor_io.dart'
    if (dart.library.js_interop) 'sqlite_executor_web.dart';

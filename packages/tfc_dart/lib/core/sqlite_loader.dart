/// Makes `sqlite3` loadable on the eLinux stations, where nothing else does.
///
/// `sqlite3_flutter_libs` declares a `linux:` CMake plugin and flutter-elinux
/// builds only plugins declaring an `elinux:` key, so the native library is
/// never bundled there — the same gap `docker/frontend/Dockerfile:119` already
/// works around by downloading `libpdfium.so` by hand. The system fallback
/// misses too: `package:sqlite3` asks for the *unversioned* `libsqlite3.so`,
/// while the station images install the `sqlite3` apt package, which ships
/// `libsqlite3.so.0` and leaves the unversioned symlink to `libsqlite3-dev`.
///
/// This is one half of the fix. The other half is the `libsqlite3.so` symlink
/// in `docker/frontend/Dockerfile` and `docker/frontend-ivi/Dockerfile.build`.
/// Either half alone is enough, which is the point: a station running an older
/// image still boots, and an image built without the app change still boots.
library;

import 'dart:ffi';
import 'dart:io';

// Prefixed because this library's own `open` parameter would otherwise shadow
// the package's `open` registry.
import 'package:sqlite3/open.dart' as sqlite3_open;

/// The symbol `sqlite3_flutter_libs` links into the executable. Its presence
/// is how `package:sqlite3` decides the library is already in the process —
/// which is the case on Windows and macOS, where the plugin does get built.
const _pluginSymbol = 'sqlite3_flutter_libs_plugin_register_with_registrar';

bool _executableProvidesPlugin() =>
    DynamicLibrary.executable().providesSymbol(_pluginSymbol);

/// Resolves the sqlite3 library on Linux, in the order `package:sqlite3`
/// itself uses, with the versioned soname appended:
///
/// 1. the running executable, if `sqlite3_flutter_libs` linked itself in;
/// 2. `libsqlite3.so` — the name `package:sqlite3` looks for;
/// 3. `libsqlite3.so.0` — what a Debian image with `libsqlite3-0` and no
///    `-dev` package actually has on disk.
///
/// If neither name resolves, the `ArgumentError` from step 3 propagates. That
/// is deliberate: a machine with no sqlite3 at all has to fail loudly, at the
/// open, naming the library it could not find — not later and not silently.
///
/// [open] and [executableProvidesPlugin] exist so the chain can be tested on
/// any operating system; production passes neither.
DynamicLibrary resolveLinuxSqlite({
  DynamicLibrary Function(String) open = DynamicLibrary.open,
  bool Function()? executableProvidesPlugin,
}) {
  final providesPlugin = executableProvidesPlugin ?? _executableProvidesPlugin;
  if (providesPlugin()) {
    return DynamicLibrary.executable();
  }

  try {
    return open('libsqlite3.so');
  } on ArgumentError {
    // The unversioned name is absent, so this is a runtime-only image. Try the
    // soname the `sqlite3` package installs.
    return open('libsqlite3.so.0');
  }
}

/// Installs [resolveLinuxSqlite] as the Linux library loader. No-op elsewhere,
/// where `sqlite3_flutter_libs` ships the library correctly and must keep
/// being the one that answers.
///
/// Top-level and capturing nothing on purpose: drift sends this to the
/// background isolate as `NativeDatabase.createInBackground(isolateSetup:)`,
/// and overriding the library is precisely what drift documents that hook for.
/// It must be called before the isolate's first sqlite3 access — passing it as
/// `isolateSetup` guarantees that.
void loadSqliteOnLinux() {
  if (!Platform.isLinux) return;
  sqlite3_open.open
      .overrideFor(sqlite3_open.OperatingSystem.linux, resolveLinuxSqlite);
}

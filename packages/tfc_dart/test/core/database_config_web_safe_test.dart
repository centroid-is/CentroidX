@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// `database_config.dart` exists for exactly one property: a Flutter web build
/// can name [DatabaseConfig] without linking `dart:ffi`. That property is
/// invisible — nothing in a normal test run fails when it is lost, and the
/// symptom appears only as five thousand dart2js errors in a build nobody runs
/// on every PR. So it is pinned here, on the import graph itself.
///
/// It is easy to lose by accident. Adding `import 'database.dart';` to
/// `database_config.dart` for one helper, or letting `secure_storage.dart`
/// reach back into a store that caches its secrets — the original form of this
/// bug — restores the edge and nothing else complains.
void main() {
  /// Every library reachable from [entry] by following `import` and `export`,
  /// with the web arm chosen for conditional imports (that is the arm dart2js
  /// compiles).
  Set<String> closureOf(String entry) {
    final seen = <String>{};
    final queue = <String>[File(entry).absolute.path];
    final directive = RegExp(
        r"""^\s*(?:import|export)\s+'([^']+)'([^;]*);""",
        multiLine: true);
    final conditional = RegExp(r"""if\s*\(\s*([\w.]+)\s*\)\s*'([^']+)'""");

    while (queue.isNotEmpty) {
      final path = queue.removeLast();
      if (!seen.add(path)) continue;
      final file = File(path);
      if (!file.existsSync()) continue;
      for (final m in directive.allMatches(file.readAsStringSync())) {
        var uri = m.group(1)!;
        for (final c in conditional.allMatches(m.group(2)!)) {
          if (c.group(1) == 'dart.library.js_interop' ||
              c.group(1) == 'dart.library.html') {
            uri = c.group(2)!;
          }
        }
        seen.add(uri);
        // Only this package's own files are walked further; a `package:` or
        // `dart:` URI is recorded and stopped at, which is all the assertions
        // below need.
        if (uri.startsWith('package:') || uri.startsWith('dart:')) continue;
        queue.add(File(Uri.file(path).resolve(uri).toFilePath()).path);
      }
    }
    return seen;
  }

  test('the settings half never reaches dart:ffi', () {
    final closure = closureOf('lib/core/database_config.dart');

    // The three edges that would each restore the whole FFI closure, named
    // individually so a failure says which one came back rather than just
    // "something did".
    expect(closure, isNot(contains('dart:ffi')),
        reason: 'dart:ffi is a compile error under dart2js, not a runtime one');
    expect(closure.where((u) => u.endsWith('database_drift.dart')), isEmpty,
        reason: 'database_drift.dart imports drift/native.dart -> sqlite3 -> '
            'dart:ffi. It holds the drift table and row types, so importing it '
            'for a type is the likely way this edge comes back.');
    expect(closure.where((u) => u.startsWith('package:drift/native')), isEmpty,
        reason: 'package:drift/drift.dart is web-safe; drift/native.dart is '
            'the FFI one');

    // `preferences.dart` is the edge this split actually had to cut: it was
    // reached through `secure_storage.dart`, which called
    // `Preferences.clearSecretCache()` on every instance swap. See the
    // generation counter in secure_storage.dart.
    expect(closure.where((u) => u.endsWith('core/preferences.dart')), isEmpty,
        reason: 'the drift-backed store; PreferencesApi is the portable half');
  });

  test('the Server Config page and the preferences widget use it', () {
    // The split is only worth having while the screens that made it necessary
    // actually take the narrow import. A revert to `core/database.dart` here
    // compiles fine on a station and silently breaks the web build.
    for (final page in [
      '../../lib/pages/server_config.dart',
      '../../lib/widgets/preferences.dart',
    ]) {
      final source = File(page).readAsStringSync();
      expect(source, contains("core/database_config.dart"),
          reason: '$page must name the settings half');
      expect(source, isNot(contains("import 'package:tfc_dart/core/database.dart'")),
          reason: '$page must not pull the drift-backed runtime');
    }
  });
}

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

  /// The other files extracted for the same property, held to the same rule.
  ///
  /// The `database_config.dart` split shipped with the arm above. The StateMan
  /// split shipped with **nothing** — five portable files were carved out of
  /// `state_man.dart` and `database.dart` on exactly the same reasoning, and
  /// their purity was asserted in commit messages and doc comments rather than
  /// measured anywhere.
  ///
  /// That gap was found by sabotage: adding `import 'state_man.dart'` to
  /// `state_man_types.dart` — which restores the whole FFI closure — did turn
  /// the suite red, but through
  /// `key_mapping_series_resolver_test.dart`'s unrelated table-name grep,
  /// which noticed a new import line while caring about something else
  /// entirely. A property defended by coincidence is not defended: rename that
  /// test's target, or relax its grep, and the FFI edge comes back silently.
  ///
  /// Each entry is asserted separately so a failure names the file that lost
  /// it.
  group('the other portable halves never reach dart:ffi either', () {
    const portable = <String>[
      'lib/core/state_man_types.dart',
      'lib/core/preferences_api.dart',
      'lib/core/retention_policy.dart',
      'lib/core/collect_config.dart',
      'lib/core/rolling_rate.dart',
    ];

    for (final entry in portable) {
      test(entry.split('/').last, () {
        // Anti-vacuity: a closure walk that finds nothing forbids nothing, and
        // a path typo would otherwise pass silently forever.
        expect(File(entry).existsSync(), isTrue,
            reason: '$entry does not exist; if it moved, point this list at '
                'its new home rather than deleting the entry — the property '
                'travels with the file.');

        final closure = closureOf(entry);
        expect(closure.length, greaterThan(1),
            reason: 'the closure of $entry is empty, so the assertions below '
                'are about nothing');

        expect(closure, isNot(contains('dart:ffi')),
            reason: 'dart:ffi is a dart2js compile error, not a runtime one');
        expect(closure, isNot(contains('dart:io')),
            reason: 'dart:io is the other half of the same wall');
        expect(closure.where((u) => u.endsWith('database_drift.dart')), isEmpty,
            reason: 'database_drift.dart reaches drift/native.dart -> sqlite3 '
                '-> dart:ffi');
        expect(closure.where((u) => u.endsWith('core/state_man.dart')), isEmpty,
            reason: 'state_man.dart is the runtime half; these files are the '
                'types it speaks. The edge back is the one that undoes the '
                'split.');
        expect(closure.where((u) => u.endsWith('core/database.dart')), isEmpty,
            reason: 'the drift-backed runtime');
        expect(
            closure.where((u) => u == 'package:open62541/open62541.dart'),
            isEmpty,
            reason: 'open62541.dart opens with dart:ffi; open62541_types.dart '
                'is the FFI-free barrel and is the one these may name');
      });
    }
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

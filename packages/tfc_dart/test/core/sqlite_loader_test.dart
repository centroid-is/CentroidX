/// The eLinux station cannot load sqlite3 without this chain.
///
/// `package:sqlite3` asks the dynamic loader for the *unversioned*
/// `libsqlite3.so`; the station images install the `sqlite3` apt package,
/// which ships only `libsqlite3.so.0` (the unversioned symlink lives in
/// `libsqlite3-dev`). Since the local store is opened before `runApp`, a
/// station without the fallback does not start at all — a black screen, not a
/// degraded feature. These tests pin the order the fallback runs in, and pin
/// the failure mode: a machine with no sqlite3 at all must throw something a
/// reader can act on, not hang.
///
/// Four of the five run anywhere, because the chain takes its opener as a
/// parameter. The fifth needs a real Linux loader and says so.
library;

import 'dart:ffi';

import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:tfc_dart/core/sqlite_loader.dart';

void main() {
  group('resolveLinuxSqlite', () {
    late List<String> asked;

    setUp(() => asked = <String>[]);

    /// A fake `DynamicLibrary.open` that records what it was asked for and
    /// succeeds only for [succeedsOn]. Everything it returns is the running
    /// executable — the identity does not matter here, the call order does.
    DynamicLibrary Function(String) opener({String? succeedsOn}) {
      return (String name) {
        asked.add(name);
        if (name == succeedsOn) return DynamicLibrary.executable();
        throw ArgumentError("Failed to load dynamic library '$name'");
      };
    }

    test('takes the unversioned name when the system provides it', () {
      final lib = resolveLinuxSqlite(
        open: opener(succeedsOn: 'libsqlite3.so'),
        executableProvidesPlugin: () => false,
      );

      expect(lib, isNotNull);
      // The versioned soname is a fallback, not a preference: asking for it
      // when the normal name resolved would change which library a working
      // machine loads.
      expect(asked, ['libsqlite3.so']);
    });

    test('falls back to libsqlite3.so.0 — the eLinux container case', () {
      final lib = resolveLinuxSqlite(
        open: opener(succeedsOn: 'libsqlite3.so.0'),
        executableProvidesPlugin: () => false,
      );

      expect(lib, isNotNull);
      expect(asked, ['libsqlite3.so', 'libsqlite3.so.0']);
    });

    test('prefers the executable when sqlite3_flutter_libs is linked in', () {
      final lib = resolveLinuxSqlite(
        open: opener(succeedsOn: 'libsqlite3.so'),
        executableProvidesPlugin: () => true,
      );

      expect(lib, DynamicLibrary.executable());
      // Windows and macOS get their sqlite3 from the plugin, and must keep
      // getting it from there: the fallback is a fallback.
      expect(asked, isEmpty);
    });

    test('propagates the failure when neither name resolves', () {
      expect(
        () => resolveLinuxSqlite(
          open: opener(succeedsOn: null),
          executableProvidesPlugin: () => false,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('libsqlite3.so.0'),
          ),
        ),
      );
      // Both were tried, and the error names the last one — the one a reader
      // has to go and install.
      expect(asked, ['libsqlite3.so', 'libsqlite3.so.0']);
    });

    test(
      'the real chain resolves a usable library on Linux',
      () {
        loadSqliteOnLinux();
        expect(sqlite3.version.libVersion, isNotEmpty);
      },
      testOn: 'linux',
    );
  });

  test('loadSqliteOnLinux is a no-op off Linux', () {
    // It is handed to drift's background isolate, so it must be callable with
    // no context of any kind — including on the platforms it does nothing for.
    expect(loadSqliteOnLinux, returnsNormally);
  });
}

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// No workspace library in the app entrypoint's closure may name a known FFI
/// barrel, following the **web** arm of every conditional import.
///
/// ## What this does and does not prove
///
/// Read the arm's name literally, because the stronger sentence is not true of
/// it. It walks **this workspace's** libraries and checks each against a short,
/// hand-written list of FFI-bearing URIs (see [_kFfiLibraries]). It does not
/// descend into pub-cache packages and it does not discover FFI by itself, so a
/// new dependency that reaches `dart:ffi` passes here and fails in
/// `flutter build web`.
///
/// That is a deliberate scope and not a defect: the offenders this catches are
/// ours to fix, usually in one line, and the ones it cannot catch are somebody
/// else's package and a different decision.
///
/// ## Why a test and not just the build
///
/// `flutter build web` already proves this, and takes about four minutes to do
/// it — then reports eleven thousand errors inside `package:open62541`, none of
/// which name the file that actually caused them. The failure is a wall of
/// noise about somebody else's code. (Measured on this repository, 2026-09-17:
/// 11,243 errors from two of our own imports.)
///
/// It is also a failure that arrives by accident rather than by intent. Every
/// HMI asset is in the page editor's closure, and the ordinary way to write a
/// new one is to copy the one beside it — so a single
/// `import 'package:open62541/open62541.dart' show DynamicValue;` in a new
/// asset re-links the whole FFI barrel. Thirty-four asset and widget files
/// carried exactly that import before this guard existed, each for a type the
/// FFI-free barrel also exports.
///
/// So this arm walks the import graph the way dart2js does and names the file.
/// It runs in under a second on the VM, and it fails on the commit that
/// introduces the edge rather than on whoever next tries to ship a web build.
///
/// ## What "the way dart2js does" means
///
/// Conditional imports resolve to their **web** arm — `if
/// (dart.library.js_interop)` — because that is the arm a web build compiles.
/// This is the whole reason a naive grep over the tree says the opposite of the
/// truth: `widgets/live_browse.dart` names an FFI file and is perfectly
/// web-safe, because the arm naming it is never compiled there.

/// The entrypoint this guard walks from. A constant so the arm that checks it
/// exists and the arm that walks it cannot drift apart.
const String _kWebEntry = 'centroid-hmi/lib/main.dart';

/// A floor under the closure size.
///
/// Not a count of anything in particular — it is far below the real figure
/// (above five hundred) and exists only so that a walk which went nowhere
/// cannot report an empty offender list. See the arm that uses it.
const int _kMinClosureFiles = 200;

void main() {
  // ---------------------------------------------------------------- vacuity
  //
  // Every arm below reports "no offenders". So does a walk that never started:
  // [_ffiImportersInWebClosureOf] skips a path it cannot find, and if the
  // entry is one of them the queue empties on the first iteration and the
  // guard passes having read nothing. That is not hypothetical — the entry is
  // a repo-relative literal, so running the suite from a package directory
  // instead of the repository root does exactly that.
  test('the walk actually happened — this file cannot pass vacuously', () {
    expect(File(_kWebEntry).existsSync(), isTrue,
        reason: 'the entry point is a repo-relative path and the working '
            'directory is the repository root. If this fails, every arm below '
            'it is meaningless rather than green.');

    // Walks itself rather than reading what the arm below left behind:
    // depending on declaration order would make the check that this file is
    // not vacuous depend on something as fragile as test ordering.
    _ffiImportersInWebClosureOf(_kWebEntry);

    expect(_lastClosureSize, greaterThan(_kMinClosureFiles),
        reason: 'the entrypoint reaches over five hundred libraries. A closure '
            'this small means the walk stopped early — a `package:` URI that '
            'resolved to nothing, or a workspace package this test no longer '
            'maps — and everything it did not reach is unchecked and silently '
            'reported as clean.');
  });

  test('no workspace library in the web closure names a known FFI barrel', () {
    final offenders = _ffiImportersInWebClosureOf(_kWebEntry);

    expect(
      offenders,
      isEmpty,
      reason: 'these files are in the app entrypoint\'s import closure and '
          'name a `dart:ffi` library, which dart2js refuses to compile:\n'
          '${offenders.map((o) => '  $o').join('\n')}\n\n'
          'Almost always the fix is one line. '
          '`package:open62541/open62541_types.dart` exports DynamicValue, '
          'NodeId, LocalizedText, EnumField and Schema with no FFI behind '
          'them, and `package:tfc_dart/core/state_man_types.dart` carries the '
          'StateMan interface and every config type. Import those instead. '
          'When the file genuinely needs a live session — a browse dialog, a '
          'connection chip, the field-description pane — put it behind an '
          'io/web seam the way `widgets/live_browse.dart` and '
          '`widgets/config/live_session_status.dart` do.',
    );
  });
}

/// The FFI libraries an app file can name: `dart:ffi` itself, plus the barrels
/// that reach it.
///
/// Spelled out rather than detected, so the arm says what it is checking — and
/// so the doc's account of what this guard does *not* cover stays honest.
/// Adding a package here is how the guard grows.
const List<bool Function(String)> _kFfiLibraries = [
  _isDartFfi,
  _isOpen62541Ffi,
  _isDriftNative,
  _isSqlite3Ffi,
];

bool _isDartFfi(String uri) => uri == 'dart:ffi';
bool _isOpen62541Ffi(String uri) =>
    uri == 'package:open62541/open62541.dart' ||
    uri.startsWith('package:open62541/src/');
bool _isDriftNative(String uri) => uri.startsWith('package:drift/native');
bool _isSqlite3Ffi(String uri) =>
    uri.startsWith('package:sqlite3/') && !uri.contains('wasm');

/// How many libraries the last walk read. Written by
/// [_ffiImportersInWebClosureOf] and read by the vacuity arm, which is the only
/// thing that may care: an offender list is not evidence that anything was
/// looked at.
int _lastClosureSize = 0;

/// The FFI-naming files reachable from [entry], following the web arm of every
/// conditional import.
List<String> _ffiImportersInWebClosureOf(String entry) {
  final root = Directory.current.path.replaceAll(r'\', '/');

  // package name -> lib directory, for this workspace's own packages. Anything
  // outside them is recorded and not walked: a `package:` URI that is not ours
  // cannot be fixed here.
  final packages = <String, String>{
    'tfc': '$root/lib',
    'centroid_hmi': '$root/centroid-hmi/lib',
  };
  for (final dir
      in Directory('$root/packages').listSync().whereType<Directory>()) {
    final lib = Directory('${dir.path}/lib');
    if (!lib.existsSync()) continue;
    final pubspec = File('${dir.path}/pubspec.yaml');
    var name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (pubspec.existsSync()) {
      final line = pubspec
          .readAsLinesSync()
          .firstWhere((l) => l.startsWith('name:'), orElse: () => '');
      if (line.isNotEmpty) name = line.substring(5).trim();
    }
    packages[name] = lib.path;
  }

  final directive = RegExp(
      r"""^[ \t]*(?:import|export)[ \t]+'([^']+)'([^;]*);""",
      multiLine: true, dotAll: true);
  final conditional = RegExp(r"""if\s*\(\s*([\w.]+)\s*\)\s*'([^']+)'""");

  bool namesFfi(String uri) => _kFfiLibraries.any((m) => m(uri));

  // One spelling per file, always. `package:` URIs resolve with forward
  // slashes and relative ones come back from `toFilePath()` with the
  // platform's — so on Windows the same library entered `seen` twice, was
  // walked twice, and an offender was reported twice: once absolute, once
  // relative, which reads as two problems rather than one.
  String norm(String p) => p.replaceAll(r'\', '/');

  String? resolve(String uri, String from) {
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final lib = packages[rest.substring(0, slash)];
      return lib == null ? null : norm('$lib/${rest.substring(slash + 1)}');
    }
    if (uri.startsWith('dart:')) return null;
    return norm(File(Uri.file(from).resolve(uri).toFilePath()).path);
  }

  final seen = <String>{};
  final queue = <String>[norm(File('$root/$entry').absolute.path)];
  final offenders = <String>{};

  while (queue.isNotEmpty) {
    final path = queue.removeLast();
    if (!seen.add(path)) continue;
    final file = File(path);
    if (!file.existsSync()) continue;
    final source = file.readAsStringSync();

    for (final match in directive.allMatches(source)) {
      var uri = match.group(1)!;
      // The web arm wins, because it is the arm a web build compiles.
      for (final arm in conditional.allMatches(match.group(2)!)) {
        if (arm.group(1) == 'dart.library.js_interop' ||
            arm.group(1) == 'dart.library.html') {
          uri = arm.group(2)!;
        }
      }
      if (namesFfi(uri)) {
        offenders.add(path.replaceFirst('$root/', ''));
      }
      final next = resolve(uri, path);
      if (next != null) queue.add(next);
    }
  }

  _lastClosureSize = seen.length;
  final sorted = offenders.toList()..sort();
  return sorted;
}

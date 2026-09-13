@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Nothing reachable from the web entrypoint may import `dart:ffi`.
///
/// ## Why a test and not just the build
///
/// `flutter build web` already proves this, and takes about five minutes to do
/// it — then reports five thousand errors inside `package:open62541`, none of
/// which name the file that actually caused them. The failure is a wall of
/// noise about somebody else's code.
///
/// It is also a failure that arrives by accident rather than by intent. Every
/// HMI asset is in the page editor's closure, and the ordinary way to write a
/// new one is to copy the one beside it — so a single
/// `import 'package:open62541/open62541.dart' show DynamicValue;` in a new
/// asset re-links the whole FFI barrel. That is exactly what happened when the
/// EtherCAT assets landed: five files, each importing the full barrel for one
/// pure type that the FFI-free barrel also exports.
///
/// So this arm walks the import graph the way dart2js does and names the file.
/// It runs in under a second on the VM, and it fails on the commit that
/// introduced the edge rather than on whoever next tries to ship a web build.
///
/// ## What "the way dart2js does" means
///
/// Conditional imports resolve to their **web** arm — `if
/// (dart.library.js_interop)` — because that is the arm a web build compiles.
/// This is the whole reason a naive grep over the tree says the opposite of the
/// truth: `live_browse.dart` names an FFI file and is perfectly web-safe,
/// because the arm naming it is never compiled there.
void main() {
  test('no library reachable from main_web.dart reaches dart:ffi', () {
    final offenders = _ffiImportersInWebClosureOf('centroid-hmi/lib/main_web.dart');

    expect(
      offenders,
      isEmpty,
      reason: 'these files are in the web entrypoint\'s import closure and '
          'name a `dart:ffi` library, which dart2js refuses to compile:\n'
          '${offenders.map((o) => '  $o').join('\n')}\n\n'
          'Almost always the fix is one line. `package:open62541/'
          'open62541_types.dart` exports DynamicValue, NodeId, LocalizedText, '
          'EnumField and Schema with no FFI behind them, and '
          '`package:tfc_dart/core/state_man_types.dart` carries the StateMan '
          'interface and every config type. Import those instead. When the '
          'file genuinely needs a live session — a browse dialog, a connection '
          'chip — put it behind an io/web seam the way `widgets/live_browse.'
          'dart` and `widgets/config/live_session_status.dart` do.',
    );
  });
}

/// The FFI-naming files reachable from [entry], following the web arm of every
/// conditional import.
List<String> _ffiImportersInWebClosureOf(String entry) {
  final root = Directory.current.path;

  // package name -> lib directory, for this workspace's own packages. Anything
  // outside them is recorded and not walked: a `package:` URI that is not ours
  // cannot be fixed here, and the two that matter are named directly below.
  final packages = <String, String>{'tfc': '$root/lib'};
  for (final dir in Directory('$root/packages').listSync().whereType<Directory>()) {
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

  final directive =
      RegExp(r"""^[ \t]*(?:import|export)[ \t]+'([^']+)'([^;]*);""", multiLine: true, dotAll: true);
  final conditional = RegExp(r"""if\s*\(\s*([\w.]+)\s*\)\s*'([^']+)'""");

  /// The FFI libraries an app file can name. `dart:ffi` itself, plus the two
  /// barrels that reach it — spelled out rather than detected, so the arm says
  /// what it is checking.
  bool namesFfi(String uri) =>
      uri == 'dart:ffi' ||
      uri == 'package:open62541/open62541.dart' ||
      uri.startsWith('package:open62541/src/') ||
      uri.startsWith('package:drift/native');

  String? resolve(String uri, String from) {
    if (uri.startsWith('package:')) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      if (slash < 0) return null;
      final lib = packages[rest.substring(0, slash)];
      return lib == null ? null : '$lib/${rest.substring(slash + 1)}';
    }
    if (uri.startsWith('dart:')) return null;
    return File(Uri.file(from).resolve(uri).toFilePath()).path;
  }

  final seen = <String>{};
  final queue = <String>[File('$root/$entry').absolute.path];
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

  final sorted = offenders.toList()..sort();
  return sorted;
}

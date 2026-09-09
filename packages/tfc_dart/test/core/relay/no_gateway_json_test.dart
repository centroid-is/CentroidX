/// There is no second config file, and this is what keeps it that way.
///
/// `relay_gateway`'s configuration world — the one whose file is named on the
/// command line — belongs to a test harness that never ships (13-CONTEXT,
/// MOUNT-03). `centroidx-backend` reads the config the backend already reads,
/// named by `CENTROID_STATEMAN_FILE_PATH`, and parses its `relay` section
/// (`lib/core/relay/relay_config.dart`). A second file beside it is a second
/// thing to mount, template and forget, which is how two deployments of one
/// process drift apart.
///
/// **Why a source scan.** The property is an absence, and an absence has no
/// behaviour to assert. Nothing can be run that demonstrates a file is never
/// read; what can be demonstrated is that the string naming it appears nowhere
/// the entrypoint can reach. `pipe_shutdown_structure_test.dart` is the
/// precedent in this package and this file copies its shape deliberately,
/// including its exemption discipline.
///
/// **Comments are stripped before matching.** `relay_config.dart`'s library
/// doc states the refusal by name, and so does this file's own doc, three
/// paragraphs up. A bare `grep -c` would count those and the gate would be
/// permanently red — after which somebody would widen it until it was
/// permanently vacuous instead. A rule that cannot be written down next to the
/// code it governs is a rule nobody inherits.
///
/// **The scan is two-sided.** An absence assertion with no matching presence
/// assertion passes just as well against a backend that reads no config at
/// all, so the second arm says where the configuration *does* come from.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The literal that must not appear. The forbidden second config world.
const String _forbidden = 'gateway.json';

/// The variable that must appear: where the backend's one config file is
/// named (`bin/main.dart:56-57`).
const String _statemanEnvVar = 'CENTROID_STATEMAN_FILE_PATH';

/// Files exempt from the ban, each named individually with a reason.
///
/// **Empty today, and it fails closed.** No file under `bin/` or `lib/`
/// mentions the forbidden string, so nothing needs excusing. When something
/// eventually does, it is added here as one entry with one sentence saying
/// why — never as a glob, and never as a directory. 12-06's structural scan
/// is the precedent: it names three one-shot CLI tools individually so that a
/// new file in `bin/` is inside the gate until somebody states otherwise. A
/// glob would have silently admitted the fourth.
const Map<String, String> _exemptions = <String, String>{};

/// Every `.dart` file reachable from the backend entrypoint's package: all of
/// `bin/` and all of `lib/`, recursively.
///
/// Deliberately the whole of `lib/`, not a hand-picked list. `bin/main.dart`
/// imports across `lib/core`, which imports onward; a curated list would be
/// a list that goes out of date the first time somebody adds an import, and
/// the scan would then pass by not looking.
List<File> _scanned() {
  final files = <File>[
    for (final dir in <String>['bin', 'lib'])
      ...Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
  ]..removeWhere((f) => _exemptions.containsKey(f.path));
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// [source] with `//` line comments and `/* */` block comments removed.
///
/// Naive on purpose, and lifted from `pipe_shutdown_structure_test.dart`: a
/// trailing `//` counts as a comment only when the quote characters before it
/// on that line balance, which keeps a `//` inside a string literal intact
/// without pulling a Dart parser into a structural test.
String _stripComments(String source) {
  final out = StringBuffer();
  var inBlock = false;
  for (final rawLine in source.split('\n')) {
    var line = rawLine;
    if (inBlock) {
      final end = line.indexOf('*/');
      if (end < 0) {
        out.writeln();
        continue;
      }
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) {
      out.writeln();
      continue;
    }
    final comment = _lineCommentAt(line);
    if (comment >= 0) line = line.substring(0, comment);
    out.writeln(line);
  }
  return out.toString();
}

int _lineCommentAt(String line) {
  var singles = 0;
  var doubles = 0;
  for (var i = 0; i < line.length - 1; i++) {
    final c = line[i];
    if (c == "'") singles++;
    if (c == '"') doubles++;
    if (c == '/' && line[i + 1] == '/' && singles.isEven && doubles.isEven) {
      return i;
    }
  }
  return -1;
}

void main() {
  late Map<String, String> code;

  setUpAll(() {
    // A blank line is emitted for every stripped line, so a reported line
    // number is the line number in the file an operator opens.
    code = <String, String>{
      for (final file in _scanned())
        // `/`-normalised for the same reason as the other structure scans:
        // `File.path` uses the platform separator, so a `contains('a/b.dart')`
        // assertion silently misses every key on Windows.
        file.path.replaceAll(r'\', '/'):
            _stripComments(file.readAsStringSync()),
    };
  });

  test('the scan actually reads the files it claims to', () {
    // A scan that silently matched nothing would pass for ever, which is the
    // failure mode of every absence assertion ever written.
    expect(code, contains('bin/main.dart'));
    expect(code, contains('lib/core/relay/relay_config.dart'));
    expect(code.length, greaterThan(40),
        reason: 'bin/ and lib/ hold ~65 Dart files; a handful means the walk '
            'stopped at the top level and the gate covers almost nothing');
    expect(code['bin/main.dart'], contains('main()'),
        reason: 'the stripper must not have eaten the file');
  });

  test('no code path reachable from the backend entrypoint names a '
      '$_forbidden', () {
    final offenders = <String>[];
    code.forEach((path, source) {
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(_forbidden)) {
          offenders.add('$path:${i + 1}: ${lines[i].trim()}');
        }
      }
    });

    expect(offenders, isEmpty,
        reason: 'MOUNT-02: the relay is configured from the backend\'s own '
            'config world — the `relay` section of the file named by '
            '$_statemanEnvVar — and from nowhere else. A second config file '
            'is how two deployments of one process drift apart, and the one '
            'that drifts is the plant. relay_gateway\'s config world belongs '
            'to a harness that never ships. If a genuine need appears, add '
            'the file to _exemptions BY NAME with a written reason rather '
            'than widening this scan.');
  });

  test('the backend reads its configuration from $_statemanEnvVar', () {
    // The positive half. Without it this file would pass unchanged against a
    // backend that had stopped reading any configuration at all — which is
    // "no gateway.json" in the most useless possible sense.
    expect(code['bin/main.dart'], contains(_statemanEnvVar),
        reason: 'bin/main.dart is where the one config file is named; if this '
            'moved, the pin above is guarding a path nothing takes');
    expect(code['lib/core/relay/relay_config.dart'], contains(_statemanEnvVar),
        reason: 'the relay config parser documents, in code, which file its '
            'section comes out of');
  });

  test('every exemption is named individually and carries a reason', () {
    _exemptions.forEach((path, reason) {
      expect(File(path).existsSync(), isTrue,
          reason: '$path is exempted but does not exist; a stale exemption is '
              'a hole nobody can see');
      expect(reason.trim(), isNotEmpty);
      expect(path, isNot(contains('*')),
          reason: 'exemptions are files, never globs: a glob admits the next '
              'file too, and nobody reviews a file it silently covers');
    });
  });
}

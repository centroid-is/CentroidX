/// Every capability the fault kit cannot exercise somewhere is visible on the
/// run report, by name.
///
/// **Why this is a test and not a review note.** `relay-packages-test` runs
/// this package on `windows-latest`. A test that cannot run there has exactly
/// two honest options — say so with a reason, or not exist — and exactly one
/// dishonest one, which is `if (!capability) return;`. An early return reports
/// as a **pass**. On the run report a leg that never ran is then
/// indistinguishable from a leg that ran everywhere, and the Windows column is
/// green because nothing was judged. That is the failure this file exists to
/// make impossible, and it is invisible to every other test in the kit because
/// each one can only speak about itself.
///
/// **What is asserted, in both directions.** A file that reaches for a
/// platform-specific mechanism must carry a named skip or a runtime capability
/// probe; and a file that carries a skip must name a mechanism that justifies
/// it. One direction catches a test that will explode on Windows, the other
/// catches a skip nobody can account for — the cheapest way to make a suite
/// green is to skip the part that fails, and a skip with no mechanism behind it
/// is what that looks like six months later.
///
/// **Reasons are judged by length**, against [_reasonFloor]. A crude measure,
/// deliberately: the reasons this kit already writes explain which half of the
/// probe failed and what stops being judged, and run to two lines. The floor
/// does not make a reason good, it rules out `'unavailable'` — and the two
/// reasons that are importable rather than literal ([openSocketCountSkipReason],
/// [lingerResetSkipReason]) are read at runtime and held to the same floor, so
/// the check follows the value instead of stopping at the identifier.
///
/// **`reject_test.dart` is on an allow-list of files that must carry no
/// platform skip.** Its trick — that a refused connection must leave the
/// listener open — is Windows-relevant behaviour, and Windows is where a wrong
/// implementation would be caught. Skipping it there would remove the only
/// place the property is in question. The assertion is the negative one: not
/// that it has a good reason, but that it has no skip at all.
///
/// **Comments are stripped before scanning.** Prose in this kit quotes the
/// anti-patterns it forbids — `oslevel_test.dart:36` writes out
/// `if (!hasRoot) return;` precisely to say not to — and an audit that flagged
/// a doc comment for describing the rule would be fixed by deleting the
/// explanation. Whole-line `//` and `///` comments go; a trailing comment after
/// code stays, because stripping those safely means parsing string literals,
/// and none of the patterns below are written that way.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

/// The directories that make up the fault kit.
const _auditedDirs = ['test/faults', 'test/channel'];

/// Shortest acceptable skip reason, in characters.
///
/// `'unavailable'` is eleven, `'not supported on windows'` is twenty-four, and
/// both are the kind of message that sends the next engineer to read the source
/// to find out what they lost. Forty forces at least a clause about the
/// capability and a clause about the consequence.
const _reasonFloor = 40;

/// Mechanisms that do not exist everywhere the CI matrix runs, and what a file
/// using one owes the run report.
///
/// The key is matched against the source. A file naming one of these must skip
/// by name or probe at runtime, because the alternative is a test that throws
/// on Windows and reads as a bug in the proxy.
const _platformMechanisms = <String, String>{
  '/proc': 'the Linux procfs descriptor table; absent on macOS and Windows',
  'lsof': 'a POSIX tool; not on Windows',
  'setRawOption': 'raw setsockopt, whose struct layout is per-kernel',
  'dnctl': 'macOS dummynet, root-only and macOS-only',
  'netem': 'Linux traffic control, root-only and Linux-only',
};

/// Files exempt from the source-scanning arms, and why.
///
/// One entry, and it has to be here: this file names every mechanism above and
/// every skip spelling below as *data* in order to search for them. A scan that
/// did not exempt it would report the audit as the worst offender in the kit —
/// four `skip:` occurrences with two-word reasons, all of them fragments of its
/// own matcher — and the person who read that as the false positive it is would
/// silence the arm rather than the file.
///
/// The exemption costs nothing real: this file carries no skip of its own, so
/// there is nothing in it for the arms to judge. If it ever acquires one, the
/// entry below is what has to be narrowed.
const _scansForThePatternsItNames = <String, String>{
  'platform_skip_audit_test.dart':
      'declares the mechanism table and the skip spellings it searches for; it '
          'opens no socket, runs no tool and skips nothing',
};

/// Files that must carry no platform skip, and why they must be judged
/// everywhere.
const _mustRunEverywhere = <String, String>{
  'reject_test.dart':
      'a refused connection must leave the listener open for the next one, '
          'which is a property of the platform\'s accept loop as much as of the '
          'proxy. Windows is where a wrong implementation shows up, so a skip '
          'there would remove the only run that could catch it',
};

void main() {
  final files = _auditedFiles();
  final scanned = [
    for (final file in files)
      if (!_scansForThePatternsItNames.containsKey(file.name)) file,
  ];

  group('the audit read the kit', () {
    test('every audited directory yielded files', () {
      print('platform-skip audit: ${files.length} files across '
          '${_auditedDirs.join(', ')}');
      expect(files, isNotEmpty,
          reason:
              'the audit found no files under ${_auditedDirs.join(' or ')}, '
              'so every assertion below passes by having nothing to judge. '
              'Check the working directory dart test was invoked from');
      for (final dir in _auditedDirs) {
        expect(files.where((f) => f.dir == dir), isNotEmpty,
            reason: '$dir contributed no files to the audit, so half the kit '
                'is unaudited while the run report says the audit passed');
      }
    });

    test('every allow-listed file still exists', () {
      final missing = [
        for (final name in [
          ..._mustRunEverywhere.keys,
          ..._scansForThePatternsItNames.keys,
        ])
          if (!files.any((f) => f.name == name)) name,
      ];
      expect(missing, isEmpty,
          reason: 'these files carry an allow-list entry and were not found by '
              'the audit. An entry for a file that moved is a rule asserted '
              'about nothing, and the file it used to name is now audited by '
              'nobody');
    });
  });

  group('no silent skip', () {
    test('no test returns early on a missing capability', () {
      final offenders = [
        for (final file in scanned)
          if (_earlyReturn.hasMatch(file.code)) file.name,
      ];
      expect(offenders, isEmpty,
          reason: 'these files gate on a capability by returning from the test '
              'body. A returned-early test reports as a pass, so on the '
              'Windows column of the matrix it is indistinguishable from one '
              'that ran and judged something. Use a group-level `skip:` '
              'carrying the probe\'s reason, the way '
              'socket_contract_test.dart does, so the run report names what '
              'stopped being judged');
    });

    test('every skip reason in the kit says what stopped being judged', () {
      final thin = <String>[];
      for (final file in scanned) {
        for (final skip in _skips(file.code)) {
          for (final reason in skip.literals) {
            if (reason.length < _reasonFloor) {
              thin.add('${file.name}: "$reason" (${reason.length} chars)');
            }
          }
        }
      }
      expect(thin, isEmpty,
          reason: 'these skip reasons are shorter than $_reasonFloor '
              'characters, which is not long enough to name both the missing '
              'capability and the property that stops being judged without it. '
              'A reason like "unavailable" costs the next engineer the whole '
              'investigation the skip was supposed to save them');
    });

    test('a skip whose reason is computed takes it from a probe', () {
      final invented = <String>[];
      for (final file in scanned) {
        for (final skip in _skips(file.code)) {
          if (skip.literals.isNotEmpty) continue;
          if (!_tracesToAProbe(skip.expression, file.code)) {
            invented.add('${file.name}: `${skip.expression}`');
          }
        }
      }
      expect(invented, isEmpty,
          reason: 'these skips are decided at runtime and their reason does '
              'not come from the probe that made the decision. Finding 13: the '
              'reason has to name which half of the probe failed, and a string '
              'written at the call site describes what the author assumed the '
              'probe would find rather than what it found');
    });

    test('the importable skip reasons clear the same floor', () {
      expect(
          openSocketCountSkipReason.length, greaterThanOrEqualTo(_reasonFloor),
          reason: 'openSocketCountSkipReason travels into a Skip() on every '
              'leak and socket-count test, so it is the single most-read skip '
              'message in the kit');
      expect(_platformMechanisms.keys.any(openSocketCountSkipReason.contains),
          isTrue,
          reason: 'openSocketCountSkipReason names none of '
              '${_platformMechanisms.keys.join(', ')}. It is the reason three '
              'test files hand to the run report in place of naming a '
              'mechanism themselves, and the source-level arm below accepts '
              'those files on the strength of that. If the mechanism stops '
              'being named here it is named nowhere');
      final linger = lingerResetSkipReason;
      if (linger != null) {
        expect(linger.length, greaterThanOrEqualTo(_reasonFloor),
            reason: 'lingerResetSkipReason is non-null on this platform, so it '
                'is what the run report will print where SO_LINGER resets are '
                'not available — and it is too short to say which half of the '
                'probe declined');
      }
    });
  });

  group('a mechanism that is not everywhere is declared as such', () {
    for (final entry in _platformMechanisms.entries) {
      test('${entry.key} is only used behind a skip or a probe', () {
        final unguarded = [
          for (final file in scanned)
            if (file.code.contains(entry.key) && !file.isGuarded) file.name,
        ];
        expect(unguarded, isEmpty,
            reason: 'these files reach for ${entry.key} (${entry.value}) and '
                'carry neither a named skip nor a runtime capability probe. On '
                'a platform without it the test does not skip, it throws — and '
                'a red Windows column that nobody can attribute is how a '
                'matrix leg gets deleted');
      });
    }

    test('every platform skip in the kit points at a mechanism', () {
      final unexplained = [
        for (final file in scanned)
          if (file.isGuarded &&
              !_platformMechanisms.keys.any(file.code.contains) &&
              !_mentionsAPlatform.hasMatch(file.code) &&
              !_probeDerived.hasMatch(file.code))
            file.name,
      ];
      expect(unexplained, isEmpty,
          reason: 'these files skip somewhere and name no mechanism, no '
              'platform and no capability probe, so nothing in them says what '
              'the missing capability is. The cheapest way to make a suite '
              'green is to skip the part that fails; a skip with nothing '
              'behind it is what that looks like once the reason has been '
              'forgotten. A file whose skip comes from a probe is accepted '
              'here because the mechanism is named where the probe lives, and '
              'the arm above reads that text at runtime');
    });
  });

  group('the matchers match', () {
    // Every arm above passes. That is either because the kit is honest or
    // because the patterns match nothing — a typo in one regex turns its arm
    // into a decoration that reports green forever, which is the same failure
    // the audit exists to catch, one level up. These cases hold the matchers
    // against samples of the thing they are looking for.
    test('the early return the kit forbids is recognised', () {
      expect(_earlyReturn.hasMatch('if (!canCountOpenSockets) return;'), isTrue,
          reason: 'the pattern that is supposed to catch a capability-gated '
              'early return does not match one written out longhand, so the '
              'arm above has been passing on every file by matching nothing');
      expect(_earlyReturn.hasMatch('if (!hasRoot) { return; }'), isTrue,
          reason: 'the braced spelling of the same early return is not '
              'recognised, so the rule can be broken by adding two characters');
      expect(_earlyReturn.hasMatch('if (bytes.isEmpty) return null;'), isFalse,
          reason: 'an ordinary guard clause is being read as a '
              'capability-gated skip, which is the false positive that gets an '
              'audit switched off');
    });

    test('a skip expression is read whole, across lines', () {
      const sample = '''
  }, skip: probe.available
      ? null
      : 'the probe declined and this is the reason it gave');
''';
      final skips = _skips(sample);
      expect(skips, hasLength(1),
          reason: 'the scanner found ${skips.length} skips in a sample with '
              'exactly one');
      expect(skips.single.literals.single,
          'the probe declined and this is the reason it gave',
          reason: 'the reason three lines below the `skip:` was not read, so a '
              'multi-line skip is judged on its condition alone');
    });

    test('a reason split across adjacent literals is judged as one sentence',
        () {
      final skips = _skips("  }, skip: 'first half ' 'second half');");
      expect(skips.single.literals.single, 'first half second half',
          reason: 'adjacent string segments are the house style for a reason '
              'too long for one line; judged separately, each half looks thin '
              'and a good reason fails the floor');
    });

    test('a skip written inside a string is not a skip', () {
      expect(_skips("expect(x, isTrue, reason: 'it becomes a Skip() later');"),
          isEmpty,
          reason: 'prose about skipping is being counted as a skip, which is '
              'how the two files that document this rule best became the two '
              'the audit accused');
    });

    test('an identifier is followed to the probe it came from', () {
      const sample = '''
  final needsProbe = probe.available ? null : probe.reason;
  }, skip: needsProbe);
''';
      expect(_tracesToAProbe('needsProbe', sample), isTrue,
          reason: 'a skip that names a local holding the probe\'s reason is '
              'being reported as invented, which fails the file that does this '
              'correctly');
      expect(_tracesToAProbe('needsProbe', '  }, skip: needsProbe);'), isFalse,
          reason: 'an identifier with no declaration in the file is being '
              'accepted, so the arm passes whether or not a probe exists');
    });
  });

  group('what must be judged everywhere, is', () {
    for (final entry in _mustRunEverywhere.entries) {
      test('${entry.key} carries no platform skip', () {
        final file = files.firstWhere((f) => f.name == entry.key);
        expect(file.code, isNot(contains('@OnPlatform')),
            reason: '${entry.key} has acquired a file-level platform skip. '
                '${entry.value}');
        expect(file.code, isNot(contains('Skip(')),
            reason: '${entry.key} has acquired a Skip(). ${entry.value}');
        expect(file.code, isNot(contains('skip:')),
            reason: '${entry.key} has acquired a group- or test-level skip. '
                '${entry.value}');
      });
    }
  });
}

/// One audited file: its name, the directory it came from, and its source with
/// whole-line comments removed.
final class _Audited {
  _Audited(this.dir, this.name, this.code);

  final String dir;
  final String name;

  /// The source with comment lines stripped — what every pattern below is
  /// matched against.
  final String code;

  /// Whether the file either skips by name or asks the platform at runtime.
  ///
  /// `Platform.is…` counts because a probe is the honest alternative to a skip:
  /// a file that measures the capability and then skips *with the probe's
  /// reason* is exactly what Finding 13 asks for. What does not count is
  /// nothing at all.
  bool get isGuarded =>
      code.contains('@OnPlatform') ||
      code.contains('Skip(') ||
      code.contains('skip:') ||
      code.contains('Platform.is');
}

/// `if (!capability) return;` in either brace style, on code lines only.
final _earlyReturn =
    RegExp(r'if\s*\(\s*!\s*[\w.]+\s*\)\s*(\{\s*)?return\s*;', multiLine: true);

/// Whether a skip's text comes from a probe rather than from the call site —
/// `…SkipReason`, `.reason`, or a `reason` local.
final _probeReason = RegExp(r'[sS]kipReason|\.reason\b|\breason\b');

/// The names a runtime capability probe goes by in this kit.
///
/// `canCountOpenSockets`, `lingerWorks`, `lingerResetSupported`, `tc.available`
/// — the shapes already in use. A file skipping on one of these is skipping on
/// a measurement, and the mechanism behind it is named where that measurement
/// is defined.
final _probeDerived = RegExp(
    r'[sS]kipReason|\bcan[A-Z]\w*|\w+Works\b|\w+Supported\b|\.available\b');

/// Whether a file names a platform at all.
final _mentionsAPlatform =
    RegExp(r"'(windows|linux|mac-os|browser)'|Platform\.is");

/// One skip site: the expression handed to `skip:`/`Skip(`, and the string
/// literals inside it.
typedef _Skip = ({String expression, List<String> literals});

/// Every skip site in [code], with its expression extracted exactly.
///
/// Exactly, rather than to the end of the line, because the house style puts a
/// multi-line ternary after `skip:` and a line-bounded capture reads only the
/// condition — reporting a skip whose reason is three lines below it as a skip
/// with no reason at all. The scan tracks bracket depth and steps over string
/// literals, and stops at the comma or the closing bracket that ends the
/// argument.
///
/// Sites *inside* a string literal are not sites. `fd_count_test.dart:80` and
/// `socket_ops_test.dart:169` both explain, in a failure message, that the
/// probe's reason "travels into a Skip()" — and a scanner that read those as
/// skips reported two reasonless skips and named the two files in the kit that
/// document this rule best. An audit whose false positives land on the most
/// careful files is one that gets deleted rather than fixed.
List<_Skip> _skips(String code) {
  final found = <_Skip>[];
  var quote = '';
  for (var i = 0; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (!code.startsWith('skip:', i) && !code.startsWith('Skip(', i)) continue;
    // Both spellings put the colon or bracket that opens the argument at i + 4.
    final expression = _argumentAt(code, i + 4);
    found.add(
        (expression: expression.trim(), literals: _literalsIn(expression)));
  }
  return found;
}

/// The argument text beginning at [from] (which indexes `:` or `(`), up to the
/// comma or closing bracket that ends it at depth zero.
String _argumentAt(String code, int from) {
  var depth = 0;
  var quote = '';
  for (var i = from + 1; i < code.length; i++) {
    final char = code[i];
    if (quote.isNotEmpty) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (')]}'.contains(char)) {
      if (depth == 0) return code.substring(from + 1, i);
      depth--;
    } else if (char == ',' && depth == 0) {
      return code.substring(from + 1, i);
    }
  }
  return code.substring(from + 1);
}

/// Every single-quoted literal in [expression], with adjacent segments joined
/// the way Dart joins them — so a two-line reason is judged as one sentence
/// rather than as two short ones.
List<String> _literalsIn(String expression) {
  final segments = RegExp(r"'((?:[^'\\]|\\.)*)'")
      .allMatches(expression)
      .map((m) => m.group(1)!);
  return segments.isEmpty ? const [] : [segments.join()];
}

/// Whether [expression] carries a probe's reason, following one level of local
/// indirection.
///
/// `skip: needsNetem` says nothing on its own; `final needsNetem = tc.available
/// ? null : tc.reason;` says everything. Refusing to follow the identifier
/// would fail the file that does this correctly and pass the one that writes
/// its excuse inline, which is backwards.
bool _tracesToAProbe(String expression, String code) {
  if (_probeReason.hasMatch(expression)) return true;
  for (final identifier in RegExp(r'\b[a-z]\w*\b').allMatches(expression)) {
    final name = identifier.group(0)!;
    final declaration =
        RegExp('(?:final|const|var)\\s+$name\\s*=([^;]*);', dotAll: true)
            .firstMatch(code);
    if (declaration != null && _probeReason.hasMatch(declaration.group(1)!)) {
      return true;
    }
  }
  return false;
}

/// Every `_test.dart` under the audited directories, read and stripped.
List<_Audited> _auditedFiles() => [
      for (final dir in _auditedDirs)
        if (Directory(dir).existsSync())
          for (final entity
              in Directory(dir).listSync()
                ..sort((a, b) => a.path.compareTo(b.path)))
            if (entity is File && entity.path.endsWith('_test.dart'))
              _Audited(
                dir,
                entity.uri.pathSegments.last,
                _withoutCommentLines(entity.readAsStringSync()),
              ),
    ];

/// Drops whole-line `//` and `///` comments.
///
/// See the library doc: the kit's prose quotes the patterns this file forbids,
/// and an audit that read documentation as evidence would be argued down rather
/// than fixed.
String _withoutCommentLines(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

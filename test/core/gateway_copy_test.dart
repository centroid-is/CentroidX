/// What `lib/` is allowed to claim about what a gateway-mode panel opens.
///
/// A source scan, not a widget test, and it exists because the claim it removes
/// was wrong in three files at once and read perfectly well in every one of
/// them. The rig measured a panel in gateway mode holding **one Postgres
/// connection to 172.18.0.6:5432 for the whole run**, for sign-in, preferences
/// and the audit trail (13-RIG-E2E-EVIDENCE FIND-C), and
/// `lib/providers/database.dart` has no transport branch that could close it.
/// Closing that dependency is Phase 17. Until then the honest sentence is "no
/// OPC UA session, no Modbus socket, no collector — and one Postgres
/// connection", and the sentence that must not come back is any variant of
/// "one WebSocket and nothing else".
///
/// **Every arm here is paired.** An absence assertion on a recursive walk
/// passes just as happily on a directory that no longer exists, on a walk that
/// matched nothing, and on a file somebody emptied. So each absence is followed
/// by the presence of the sentence that replaced it, and the walk itself is
/// asserted to have read a plausible number of files before anything is
/// concluded from it.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/path_separators.dart';

/// One `lib/` file and the line that offended, so a failure names the place
/// instead of printing an empty list.
typedef _Hit = ({String path, int line, String text});

/// Every `*.dart` under `lib/`, read once.
final List<({String path, List<String> lines})> _libFiles = _readLib();

List<({String path, List<String> lines})> _readLib() {
  final dir = Directory('lib');
  if (!dir.existsSync()) {
    throw StateError(
      'lib/ was not found from ${Directory.current.path}. This scan concludes '
      'nothing about a directory it did not read.',
    );
  }
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      // `/`-normalised: the assertions below name paths like
      // 'lib/providers/state_man.dart', which never match a Windows
      // backslash path.
      .map((f) =>
          (path: withForwardSlashes(f.path), lines: f.readAsLinesSync()))
      .toList(growable: false);
}

/// Three consecutive source lines, read as prose rather than as Dart.
///
/// **This is the part that makes the scan hard to defeat by accident.** Both
/// places the false claim lived were wrapped — a doc comment across two `///`
/// lines and a `Text` built from four adjacent string literals — so a literal
/// line-by-line grep for "no OPC UA session" finds neither, and an author
/// re-wrapping a paragraph would silently un-pin every phrase below. So each
/// window strips the comment marker, joins the seam between adjacent Dart
/// string literals, collapses whitespace and lower-cases. Three lines is
/// enough for every sentence this file is about; the line reported is the
/// window's first, which is where a reader should start looking.
String _window(List<String> lines, int i) => lines
    .skip(i)
    .take(3)
    .map((l) => l.replaceFirst(RegExp(r'^\s*///?\s?'), ''))
    .join(' ')
    // `'a ' 'b'` and `"a " "b"` are one string to a reader and two to a grep.
    .replaceAll(RegExp(r"'\s*'"), '')
    .replaceAll(RegExp(r'"\s*"'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .toLowerCase();

/// Every occurrence of [needle] in `lib/`, case-insensitively and across
/// wrapping.
List<_Hit> _scan(String needle) {
  final lowered = needle.toLowerCase();
  final hits = <_Hit>[];
  for (final file in _libFiles) {
    for (var i = 0; i < file.lines.length; i++) {
      final window = _window(file.lines, i);
      if (!window.contains(lowered)) continue;
      // One hit per phrase per place: a three-line window slides, so the same
      // sentence would otherwise be reported up to three times.
      if (hits.isNotEmpty &&
          hits.last.path == file.path &&
          i - hits.last.line < 3) {
        continue;
      }
      hits.add((path: file.path, line: i + 1, text: window));
    }
  }
  return hits;
}

/// Whether [path] contains [needle], across wrapping.
bool _says(String path, String needle) => _scan(needle)
    .any((h) => h.path == path);

String _describe(List<_Hit> hits) =>
    hits.map((h) => '${h.path}:${h.line}: ${h.text}').join('\n');

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('the scan itself', () {
    // The anti-vacuity arm. Everything below is an absence assertion, and an
    // absence assertion over an empty list is the cheapest green in testing.
    test('reads the whole of lib/, recursively', () {
      expect(_libFiles.length, greaterThan(100),
          reason: 'a walk that matched almost nothing would make every '
              'absence assertion below vacuous');
      expect(
        _libFiles.map((f) => f.path),
        containsAll(<String>[
          'lib/pages/server_config.dart',
          'lib/providers/state_man.dart',
          'lib/core/gateway_config.dart',
        ]),
        reason: 'the three files that carried the false claim must be inside '
            'the set this scan walks, or it proves nothing about them',
      );
    });

    // Two files, not one. A scan that only ever reaches into a single path is
    // a `grep` on that path wearing a recursive walk's hat — sabotage arm 12
    // puts the phrase back in `state_man.dart` AND in `server_config.dart` and
    // expects to be named both times.
    test('and would find a phrase in any of them', () {
      expect(_scan('one websocket for values').map((h) => h.path),
          contains('lib/providers/state_man.dart'),
          reason: 'a control: the scan finds a string that IS there, in a file '
              'other than the one the arms below are mostly about');
      expect(_scan('transportmode.parse').map((h) => h.path),
          contains('lib/core/gateway_config.dart'));
    });
  });

  group('nothing else', () {
    test('no file in lib/ claims the panel opens one WebSocket and nothing '
        'else', () {
      // Scoped to the claim, not to the two English words. `nothing else` is
      // ordinary prose and appears ~50 times in `lib/` in doc comments that
      // have nothing to do with transports ("Reads of `audit_entry`, and
      // nothing else"), including one in `gateway_link_status.dart` that is
      // both correct and load-bearing ("this panel trusts that file and
      // nothing else"). Banning the bare phrase would mean rewriting forty
      // unrelated files, and a rule that broad stops being read.
      //
      // What is banned is the *claim*: the socket named beside the phrase, or
      // the phrase attached to what this panel **opens**. Both of the two
      // original spellings are caught — `state_man.dart`'s bare "One WebSocket
      // and nothing else" by the first arm, and "this panel opens … one
      // WebSocket and nothing else" by either.
      // `opens` alone is still too wide across a three-line window — one
      // `proposal_banner.dart` paragraph opens an editor three lines above an
      // unrelated "and nothing else" — so the window must also name something
      // this panel could open.
      const transport = ['websocket', 'socket', 'connection', 'postgres'];
      final offenders = _scan('and nothing else')
          .where((h) =>
              h.text.contains('websocket and nothing else') ||
              (h.text.contains('opens') &&
                  transport.any((t) => h.text.contains(t))))
          .toList();

      expect(offenders, isEmpty,
          reason: 'the rig measured one Postgres connection live throughout '
              'gateway mode (FIND-C); a panel that opens "one WebSocket and '
              'nothing else" is a claim this codebase cannot make. '
              'Offending lines:\n${_describe(offenders)}');
    });

    test('and none of them says the station opens no connections of its own',
        () {
      final offenders = _scan('no connections of its own');
      expect(offenders, isEmpty,
          reason: 'FIND-C again, in the sentence an operator actually reads. '
              'Offending lines:\n${_describe(offenders)}');
    });

    test('and none of them says the database settings belong to the gateway',
        () {
      // Two terms in one window rather than one long sentence: the OPC UA,
      // JBTM and Modbus settings genuinely DO belong to the gateway and this
      // page says so, so the claim to catch is specifically the one that drags
      // the database in with them.
      final offenders = _scan('belong to the gateway')
          .where((h) => h.text.contains('database'))
          .toList();
      expect(offenders, isEmpty,
          reason: 'the OPC UA, JBTM and Modbus settings do; the database is '
              'still this station\'s own, at an address that differs per '
              'station (project memory svn-db-ip-per-station). '
              'Offending lines:\n${_describe(offenders)}');
    });

    test('and none of them says gateway mode opens no Postgres pool', () {
      final offenders = _scan('no postgres pool');
      expect(offenders, isEmpty,
          reason: 'Offending lines:\n${_describe(offenders)}');
    });
  });

  // The paired half. Four absences on their own are satisfied by four empty
  // files; these say the honest sentence is present in each place the false one
  // used to be.
  group('and the honest sentence is present where the false one was', () {
    for (final path in const [
      'lib/pages/server_config.dart',
      'lib/providers/state_man.dart',
      'lib/core/gateway_config.dart',
    ]) {
      test('$path names the Postgres connection', () {
        final source = _read(path);
        expect(source, contains('Postgres'),
            reason: 'this file used to assert the opposite; saying nothing at '
                'all would pass the absence arms above and leave the next '
                'reader to rediscover FIND-C on a rig');
      });
    }

    test('server_config.dart says what gateway mode does NOT open, too', () {
      const path = 'lib/pages/server_config.dart';
      expect(_says(path, 'no OPC UA session'), isTrue,
          reason: 'the honest sentence names both halves: what is not opened '
              'and what still is');
      expect(_says(path, 'no Modbus socket'), isTrue);
      expect(_says(path, 'no collector'), isTrue);
    });
  });

  // The colour convention, on the one new widget file. The pixel half — whether
  // the colour actually reaches the image — is plan 15-07's, which owns the
  // themed goldens; this is the half that can be measured without one.
  group('the status row obeys the colour convention', () {
    const path = 'lib/widgets/gateway_link_status_row.dart';

    test('it names no raw Material colour constant', () {
      final offenders = RegExp(r'\bColors\.').allMatches(_read(path)).toList();
      expect(offenders, isEmpty,
          reason: 'every colour comes from HmiStateColors, which is themed. '
              'lib/widgets/connection_status_chip.dart is 100% raw Colors.* '
              'and is a KNOWN pre-existing violation that is deliberately NOT '
              'in scope — do not "fix" it as a side effect of this rule; it is '
              'three cards\' worth of golden churn for no Phase 15 criterion');
    });

    test('and it does not borrow colorScheme.outline', () {
      expect(_read(path), isNot(contains('colorScheme.outline')),
          reason: 'neither Solarized scheme sets outline, so the edge is '
              'invisible on dark (project memory '
              'solarized-outline-is-invisible); use onSurface with alpha');
    });

    test('and it reaches for HmiStateColors.of instead', () {
      // The paired presence half: the two absences above both pass on a file
      // that renders no colour at all.
      expect(_read(path), contains('HmiStateColors.of('));
    });

    test('and it never renders a CircularProgressIndicator', () {
      // Criterion 2 is that the UI stops pretending. Even `connecting` says
      // what it is dialling and for how long, in words.
      expect(_read(path), isNot(contains('CircularProgressIndicator')));
    });
  });
}

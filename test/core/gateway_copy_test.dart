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
      .map((f) => (path: f.path, lines: f.readAsLinesSync()))
      .toList(growable: false);
}

/// Every occurrence of [needle] in `lib/`, case-insensitively.
List<_Hit> _scan(String needle) {
  final lowered = needle.toLowerCase();
  return [
    for (final file in _libFiles)
      for (var i = 0; i < file.lines.length; i++)
        if (file.lines[i].toLowerCase().contains(lowered))
          (path: file.path, line: i + 1, text: file.lines[i].trim()),
  ];
}

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
      final hits = _scan('and nothing else');
      // Scoped to the claim, not to the two English words. `nothing else` is
      // ordinary prose and appears ~50 times in `lib/` in doc comments that
      // have nothing to do with transports ("Reads of `audit_entry`, and
      // nothing else"), including one in `gateway_link_status.dart` that is
      // both correct and load-bearing ("this panel trusts that file and
      // nothing else"). Banning the bare phrase would mean rewriting forty
      // unrelated files, and a rule that broad stops being read.
      final offenders = hits
          .where((h) =>
              h.text.toLowerCase().contains('websocket') ||
              h.text.toLowerCase().contains('connection') ||
              h.text.toLowerCase().contains('postgres'))
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
      final offenders = _scan('settings belong to the gateway');
      expect(offenders, isEmpty,
          reason: 'the OPC UA, JBTM and Modbus settings do; the database '
              'settings are still this station\'s own. '
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
      final source = _read('lib/pages/server_config.dart');
      expect(source, contains('no OPC UA session'));
      expect(source, contains('no Modbus socket'));
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

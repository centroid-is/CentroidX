/// ALRM-01, pinned in the source rather than in a timing test.
///
/// Phase 14 exists because `bin/main.dart` built a **second** `StateMan` —
/// `alias: 'alarmman'`, `useIsolate: false` — purely so an `AlarmMan` could
/// evaluate alarm rules on the backend. That is a second OPC UA session per
/// configured server, against controllers that count sessions, on the main
/// isolate, for a job the relay's own value source already does. This plan
/// deletes it. These arms are what stop it coming back.
///
/// ## Why a source scan, and why that is not a weaker test
///
/// Every property below is invisible to a behavioural test:
///
///  * A second `StateMan` does not change a single answer the backend gives.
///    It costs sessions on a PLC that is not in CI, and the failure it produces
///    is a controller refusing the *next* connection — days later, in a
///    different process.
///  * `alarmEngine.activeAlarms().listen((_) {})` re-added would change nothing
///    at all: 14-05's engine evaluates whether or not anybody listens, which is
///    precisely the defect the old `AlarmMan` had and precisely why a
///    behavioural arm cannot see the workaround's return.
///  * An engine started *before* the spawn loop still starts, still logs, still
///    publishes an empty active set, and silently subscribes to keys no worker
///    owns (P-4). Nothing throws. Nothing is late. Alarms simply never fire.
///
/// So these are structural, in the shape of
/// `test/core/pipe_shutdown_structure_test.dart` — the pin that has been shown
/// to bite four times — and for its stated reason: *"a timing test cannot keep
/// that true."*
///
/// ## Comments are stripped before every match
///
/// Every file scanned here documents at length **why** it must not do the
/// banned thing, and several of them spell the banned string while doing so
/// (`backend_alarms.dart` has a paragraph headed *"there is no `historyToDb`"*;
/// `alarm_stamp.dart` states that `DateTime.now` does not appear in it). Prose
/// that could self-invalidate the gate would make the gate worthless, so the
/// scan reads code only. Sabotage (f) of this plan adds a `///` comment
/// containing `activeAlarms()` to `bin/main.dart` and requires arm 3 to stay
/// **green**, which is how the stripping itself is shown to work.
library;

import 'dart:io';

import 'package:test/test.dart';

// --------------------------------------------------------------- the roster

/// The composition root. Arms 1-6 are all about this one file.
const String _mainPath = 'bin/main.dart';

/// The backend alarm path, in full.
///
/// Named individually rather than globbed, so the roster **fails closed**: a
/// glob that matched nothing would make every absence arm below vacuously
/// green, and a file renamed out from under this list would take its pin with
/// it silently. Arm 8 asserts each of these was read and is non-empty after
/// stripping.
const List<String> _alarmPathFiles = <String>[
  'lib/core/alarm.dart',
  'lib/core/alarm_stamp.dart',
  'lib/core/relay/backend_alarms.dart',
  'lib/core/relay/backend_alarm_history.dart',
  'lib/core/relay/alarm_rule_watcher.dart',
];

/// The three source trees `historyToDb` must not appear in (arm 7).
///
/// The repo-root `lib` is the Flutter app, reached relatively because `bin/` and
/// a sibling package are not addressable by any `package:` URI. It is in the
/// scan because the flag's other half lived in the app's alarm provider, and a
/// gate that only watched the backend would let it come back on the panel.
const List<String> _historyScanRoots = <String>[
  'lib',
  'bin',
  '../../lib',
];

/// The ONE place `historyToDb` may still be spelled, and the fragment that says
/// it is a refusal rather than a flag.
///
/// `backend_alarms.dart` explains, in a message an operator can read in a
/// container log, that the engine writes history unconditionally and there is
/// no switch to check. That sentence has to name the thing that does not
/// exist. Arm 7 permits exactly this line and nothing else — it does not
/// permit "a string literal somewhere", because
/// `prefs.getBool('historyToDb')` is a string literal too.
const String _historyToDbRefusalFragment =
    'There is no historyToDb flag to check';

void main() {
  late Map<String, String> code;
  late Map<String, String> historyScan;

  setUpAll(() {
    code = <String, String>{
      for (final path in <String>[_mainPath, ..._alarmPathFiles])
        path: _stripComments(File(path).readAsStringSync()),
    };
    historyScan = <String, String>{
      for (final file in _historyScanRoots.expand(_dartFilesUnder))
        // `/`-normalised: `File.path` uses the platform separator, so on
        // Windows every key came back with backslashes and each
        // `contains('bin/main.dart')` assertion below missed — the scan read
        // the right files and the map could not be searched. Found by CI on
        // windows-latest only.
        file.path.replaceAll(r'\', '/'):
            _stripComments(file.readAsStringSync()),
    };
  });

  // ------------------------------------------------------------------ arm 8
  //
  // First, deliberately. Everything below it is an absence assertion, and an
  // absence assertion against a file that was never read passes for ever.

  test('arm 8: the scan actually reads the files it claims to', () {
    expect(code.keys, containsAll(<String>[_mainPath, ..._alarmPathFiles]),
        reason: 'the roster is named file by file so it fails closed. If one '
            'of these has been renamed, rename it HERE too — do not delete '
            'the entry, or its pin disappears with it');

    code.forEach((path, source) {
      expect(source.trim(), isNotEmpty,
          reason: '$path is empty after comment stripping, which would make '
              'every absence arm below vacuously green');
    });

    // Landmarks, so a file that was gutted rather than renamed is caught too.
    expect(code[_mainPath], contains('void main()'));
    expect(code[_mainPath], contains('pipe.addWorker('));
    expect(code['lib/core/relay/backend_alarms.dart'],
        contains('final class AlarmEngine'));

    expect(historyScan, isNotEmpty);
    for (final root in _historyScanRoots) {
      expect(historyScan.keys.any((path) => path.startsWith('$root/')), isTrue,
          reason: 'the historyToDb scan read nothing under "$root". A scan '
              'that matched no files is a gate that passes for ever');
    }
  });

  // ------------------------------------------------- arms 1-3: what is gone

  test('arm 1: bin/main.dart constructs no second StateMan', () {
    final offenders = _linesContaining(code[_mainPath]!, 'StateMan.create(');

    expect(offenders, isEmpty,
        reason: 'ALRM-01. The composition root used to build a second '
            'StateMan (alias "alarmman", useIsolate: false) so that an '
            'AlarmMan could evaluate rules on the backend — one extra OPC UA '
            'session per configured server, against controllers that count '
            'them, on the main isolate. The alarm engine reads the SAME value '
            'source the relay reads; it needs no session of its own. If a '
            'second session is ever genuinely required, that is a decision '
            'somebody writes down, not the silent consequence of a line here.'
            '\nFound: ${offenders.join('\n       ')}');
  });

  test('arm 2: the name "alarmman" appears nowhere in bin/main.dart', () {
    final offenders = _linesContaining(code[_mainPath]!, 'alarmman');

    expect(offenders, isEmpty,
        reason: 'the alias is what the PLC logs the second session under, so '
            'the literal string is the most direct evidence the block is '
            'back. Case-sensitive and separate from arm 1 on purpose: a '
            'session reconstructed some other way would still carry this '
            'alias, because whoever brought it back would copy it.'
            '\nFound: ${offenders.join('\n       ')}');
  });

  test('arm 3: no AlarmMan and no activeAlarms() gate workaround in '
      'bin/main.dart', () {
    final alarmMan = _linesContaining(code[_mainPath]!, 'AlarmMan');
    final gate = _linesContaining(code[_mainPath]!, 'activeAlarms(');

    expect(alarmMan, isEmpty,
        reason: 'AlarmMan is the PANEL class. Its evaluators only wire up when '
            'somebody listens to activeAlarms(), it holds a StateMan of its '
            'own, and 14-05 replaced it on the backend with AlarmEngine — '
            'which evaluates with nobody listening and reads the relay\'s '
            'value source. Two implementations of "which alarms are active" '
            'in one process is two answers.'
            '\nFound: ${alarmMan.join('\n       ')}');

    expect(gate, isEmpty,
        reason: 'this is the arm the pin exists for. `activeAlarms().listen('
            '(_) {})` was a subscription to nothing, added because AlarmMan '
            'evaluated nothing without one. Re-added against AlarmEngine it '
            'would change NO behaviour at all — the engine evaluates '
            'regardless — so no behavioural test could ever see it come back, '
            'and the next reader would take it as a requirement. Its '
            'confession comment goes with it; stripping comments therefore '
            'does not weaken this arm.'
            '\nFound: ${gate.join('\n       ')}');
  });

  // ------------------------------------------ arms 4-5: what must be ordered

  test('arm 4: the alarm engine is started AFTER every worker is registered',
      () {
    final main = code[_mainPath]!;

    final workers = 'pipe.addWorker('.allMatches(main).map((m) => m.start);
    expect(workers, isNotEmpty,
        reason: 'no worker is registered at all — the spawn loop this '
            'ordering is measured against is gone');

    final start = main.indexOf('alarmEngine.start()');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'the engine must be started explicitly. Constructing it starts '
            'nothing: AlarmEngine.start() is what loads the configuration, '
            'builds one watcher per rule, reconciles the alarm_history rows a '
            'previous process left open, and subscribes.');

    final lastWorker = workers.reduce((a, b) => a > b ? a : b);
    expect(lastWorker, lessThan(start),
        reason: 'D-7 / P-4. A subscribe for a key no worker owns costs no '
            'message and is silently dropped, so an engine started before the '
            'spawn loop still starts, still logs, still publishes an empty '
            'active set — and never fires an alarm. Nothing throws and nothing '
            'is late; the plant is simply unmonitored. Compared by character '
            'index rather than by hope, and against the LAST addWorker rather '
            'than the first, because the M2400 and Modbus loops come after the '
            'OPC UA one and a start() between them would miss those workers '
            'alone.'
            '\nlast pipe.addWorker( at line ${_lineOf(main, lastWorker)}, '
            'alarmEngine.start() at line ${_lineOf(main, start)}');
  });

  test('arm 5: the value source is built OUTSIDE the relay block, so the '
      'WebSocket being off does not turn alarms off', () {
    final main = code[_mainPath]!;

    final live = main.indexOf('BackendLiveValues(');
    final sweep = main.indexOf('BackendFreshnessSweep(');
    final guard = main.indexOf('if (relayConfig != null)');

    expect(guard, greaterThanOrEqualTo(0),
        reason: 'the relay block must still be guarded by a null config — off '
            'by default is the upgrade-safety property 13-06 shipped');
    expect(live, greaterThanOrEqualTo(0),
        reason: 'bin/main.dart must build the live half itself. Built inside '
            'composeBackendRelay it exists only when a relay section does');
    expect(sweep, greaterThanOrEqualTo(0),
        reason: 'and the freshness sweep with it — the engine must read '
            'through the watchdog, or a rule evaluates a value that has gone '
            'quiet as though it were current');

    expect(live, lessThan(guard),
        reason: 'D-8 / P-5. The relay is OFF BY DEFAULT and SVN runs that way '
            'today. A value source built inside the relay block means turning '
            'the WebSocket off turns alarm evaluation off — a regression '
            'against the very thing this phase deleted, because the duplicate '
            '"alarmman" StateMan evaluated unconditionally. A deployment '
            'choice about a WebSocket must not decide whether the plant is '
            'monitored.'
            '\nBackendLiveValues( at line ${_lineOf(main, live)}, the relay '
            'guard at line ${_lineOf(main, guard)}');
    expect(sweep, lessThan(guard),
        reason: 'the sweep is half of the same value source and moves with it. '
            'A sweep inside the guard around a live half outside it would '
            'also be two objects registering the pipe\'s onWorkerDied '
            'callback, and the second silently wins.'
            '\nBackendFreshnessSweep( at line ${_lineOf(main, sweep)}, the '
            'relay guard at line ${_lineOf(main, guard)}');
  });

  // --------------------------------------------- arms 6-7: what may be said

  test('arm 6: DateTime.now is spelled exactly once on the whole backend '
      'alarm path, at the composition root', () {
    final atRoot = 'DateTime.now'.allMatches(code[_mainPath]!).length;

    expect(atRoot, 1,
        reason: 'D-2. The clock is injected, and bin/main.dart is the one '
            'place allowed to read the real one — that is what a composition '
            'root IS. Exactly one, not at-least-one: two reads of a real clock '
            'inside one logical instant can straddle a second, and two '
            'suppliers is two opinions about when the plant did something.');

    for (final path in _alarmPathFiles) {
      final hits = _linesContaining(code[path]!, 'DateTime.now');
      expect(hits, isEmpty,
          reason: 'D-2, the other half. $path may not read a clock. An alarm '
              'instant is a fact about the PLANT — resolveAlarmStamp prefers '
              'the reading\'s own sourceTimestamp and labels what it used — '
              'and a DateTime.now() here is this machine\'s wristwatch quietly '
              'replacing it. Five files, not one, because criterion 3 names '
              'only the activation edge and the CLEARING edge '
              '(alarm.dart:444) is the one that had the defect.'
              '\nFound in $path: ${hits.join('\n       ')}');
    }
  });

  test('arm 7: historyToDb exists nowhere as an identifier, in either '
      'package or in the app', () {
    final offenders = <String>[];
    final permitted = <String>[];

    historyScan.forEach((path, source) {
      for (final line in _linesContaining(source, 'historyToDb')) {
        if (line.contains(_historyToDbRefusalFragment)) {
          permitted.add('$path: $line');
        } else {
          offenders.add('$path: $line');
        }
      }
    });

    expect(offenders, isEmpty,
        reason: 'D-6, 14-07. A boolean that decides whether an object writes '
            'to a shared database is a boolean somebody eventually sets '
            'wrong, and the cost is two processes writing one plant\'s '
            'history into one table with no way to tell the copies apart. The '
            'flag, its config class, its branch, the method behind it and the '
            'generated serializer are all gone; the engine\'s '
            'AlarmHistoryWriter always writes. Permitted by name rather than '
            'by "it is only a string": prefs.getBool(\'historyToDb\') is a '
            'string too.'
            '\nFound: ${offenders.join('\n       ')}');

    expect(permitted, hasLength(1),
        reason: 'exactly one sentence in the repo may name the flag that does '
            'not exist — the engine\'s refusal message. Zero would mean it was '
            'reworded and this gate is now permitting a fragment nobody '
            'writes; more than one would mean the exemption is being copied '
            'around.'
            '\nFound: ${permitted.join('\n       ')}');
    expect(permitted.single, contains('backend_alarms.dart'));
  });
}

// ----------------------------------------------------------- source scanning
//
// Copied from `test/core/pipe_shutdown_structure_test.dart` rather than
// imported, for the reason `backend_composition_test.dart` records about the
// same duplication: the helpers there are library-private, and making them
// public so a second file could share them would make a pin that has bitten
// four times editable from somewhere other than the pin.

/// Every `.dart` file under [root], recursively. Empty when [root] is absent,
/// which arm 8 turns into a failure rather than into silence.
Iterable<File> _dartFilesUnder(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const <File>[];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
}

/// Every line of [source] containing [needle], with its 1-based line number.
///
/// The line, not a count: `Expected: <0> Actual: <1>` on CI tells the next
/// person nothing about which file, which line, or what to do.
List<String> _linesContaining(String source, String needle) {
  final out = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains(needle)) out.add('line ${i + 1}: ${lines[i].trim()}');
  }
  return out;
}

/// The 1-based line number [offset] falls on.
int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// [source] with `//` line comments and `/* */` block comments removed,
/// **preserving line numbers** so a failure can name a line in the real file.
///
/// Naive on purpose: a trailing `//` is only treated as a comment when the
/// quote characters before it on that line balance, which keeps a `//` inside a
/// string literal intact without pulling a Dart parser into a structural test.
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

/// Where a real `//` comment starts on [line], or -1.
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

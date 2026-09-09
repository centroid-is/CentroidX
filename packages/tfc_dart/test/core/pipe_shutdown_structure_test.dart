/// PIPE-13, pinned in the source rather than on the clock.
///
/// The measured stall is `StateMan.close()` (`state_man.dart:2249-2259`), which
/// awaits an OPC UA `disconnect()`/`delete()` and has been seen to take 5.76 s.
/// A backend that takes seconds to stop is a backend Docker kills mid-write, so
/// the shutdown path must be `Isolate.kill(priority: immediate)` and nothing
/// else.
///
/// A timing test cannot keep that true: the stall only appears against a real
/// blackholed server, so a fast run proves nothing and CI would never see the
/// regression. This is therefore a **source scan** — a meta test, deliberately.
/// Its whole value is that it fails when somebody adds the await back, so it is
/// written to be shown to bite (SUMMARY records the run where a temporary
/// `await stateMan.close()` in `main`'s shutdown made it red).
///
/// Comments are stripped before the scan. Every one of the scanned files
/// documents at length WHY it must not call these, and prose that could
/// self-invalidate the gate would make the gate worthless.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The calls no shutdown path may make.
///
/// `disconnect()` and `delete()` are the open62541 teardown pair; `.close(` is
/// `StateMan.close()`, which awaits both. None of them appear anywhere in the
/// scanned files today, so the scan is a flat ban rather than a control-flow
/// analysis — simpler, and strictly harder to sneak past.
const _forbidden = <String>['.close(', 'disconnect(', '.delete('];

/// One-shot CLI tools in `bin/`, exempt from the ban.
///
/// Each of these runs, prints and exits; a `disconnect()` in a program whose
/// next statement is the end of `main` costs a human at a terminal a few
/// seconds and nothing else. The gate is about the LONG-LIVED backend, where
/// the same await is a container that misses its stop deadline and gets SIGKILL
/// mid-write.
///
/// Named individually rather than excluded by a narrower glob, so the list
/// fails closed: a new file in `bin/` is inside the gate until somebody states,
/// here, that it is a one-shot tool.
const _oneShotTools = <String>{
  'read_key.dart', // reads one key off OPC UA and exits
  'generate_certs.dart', // writes a cert pair and exits
  'page_geometry.dart', // dumps page geometry and exits
};

/// Everything on main's or the pipe's shutdown path.
///
/// `lib/core/data_acquisition_isolate.dart` is NOT here: it closes its own
/// `ReceivePort`s and its message controller, which are main-side objects with
/// no upstream behind them and no stall to contribute.
List<File> _scanned() {
  final files = <File>[
    ...Directory('bin').listSync().whereType<File>().where((f) =>
        f.path.endsWith('.dart') &&
        !_oneShotTools.contains(f.uri.pathSegments.last)),
    ...Directory('lib/core')
        .listSync()
        .whereType<File>()
        .where((f) {
      final name = f.uri.pathSegments.last;
      return name.startsWith('pipe') && name.endsWith('.dart');
    }),
  ];
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// [source] with `//` line comments and `/* */` block comments removed.
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
      if (end < 0) continue;
      line = line.substring(end + 2);
      inBlock = false;
    }
    final blockStart = line.indexOf('/*');
    if (blockStart >= 0) {
      inBlock = true;
      line = line.substring(0, blockStart);
    }
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//')) continue;
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

/// The body of a top-level or member function whose declaration contains
/// [signature], brace-matched. Empty when there is no such function.
String _bodyOf(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return '';
  final open = source.indexOf('{', start);
  if (open < 0) return '';
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  return '';
}

/// The whole statement beginning at [anchor], up to its terminating `;`.
///
/// Empty when [anchor] is absent — which reads as "the thing is not there" in
/// every arm that uses it, and is the answer those arms want.
String _statementAt(String source, String anchor) {
  final start = source.indexOf(anchor);
  if (start < 0) return '';
  final end = source.indexOf(';', start);
  return end < 0 ? source.substring(start) : source.substring(start, end + 1);
}

void main() {
  late Map<String, String> code;

  setUpAll(() {
    code = <String, String>{
      for (final file in _scanned())
        // `/`-normalised: `File.path` uses the platform separator, so on
        // Windows every key came back with backslashes and each
        // `contains('bin/main.dart')` assertion below missed — the scan read
        // the right files and the map could not be searched. Found by CI on
        // windows-latest only.
        file.path.replaceAll(r'\', '/'):
            _stripComments(file.readAsStringSync()),
    };
  });

  test('the scan actually reads the files it claims to', () {
    expect(code.keys, contains('bin/main.dart'));
    expect(code.keys, contains('lib/core/pipe_main_endpoint.dart'));
    expect(code.keys, contains('lib/core/pipe_worker_endpoint.dart'));
    // A scan that silently matched nothing would pass forever.
    expect(code['bin/main.dart'], contains('shutdown('));
  });

  test('no shutdown path awaits a graceful teardown', () {
    final offenders = <String>[];
    code.forEach((path, source) {
      for (final call in _forbidden) {
        if (!source.contains(call)) continue;
        for (final line in source.split('\n')) {
          if (line.contains(call)) offenders.add('$path: ${line.trim()}');
        }
      }
    });

    expect(offenders, isEmpty,
        reason: 'PIPE-13: shutdown is Isolate.kill(priority: immediate) and '
            'nothing else. StateMan.close() awaits an OPC UA disconnect() and '
            'delete(); that await has been measured at 5.76s and is what this '
            'phase removed. If one of these is genuinely needed off a shutdown '
            'path, move it out of bin/ and lib/core/pipe*.dart rather than '
            'widening this gate.');
  });

  test('one shutdown covers SIGTERM and the config-watch restart', () {
    final main = code['bin/main.dart']!;
    // The whole statement, not the line: the handler is a wrapped chain, and a
    // line-at-a-time scan would report the absence of its own last line.
    expect(_statementAt(main, 'ProcessSignal.sigterm'), contains('shutdown('),
        reason: 'SIGTERM must not exit(0) past the workers');

    // R-4: the config-watch restart is a shutdown too. It fires on every
    // operator config save, so a path that skipped the kill would put the
    // stall back into the most common restart in the plant.
    final restart = _bodyOf(main, 'configWatcher.changes.listen');
    expect(restart, contains('shutdown('),
        reason: 'the config-watch restart must route through the same '
            'shutdown() as SIGTERM');

    // Exactly one implementation, reached from both.
    expect('shutdown('.allMatches(main).length, greaterThanOrEqualTo(3),
        reason: 'one definition plus both call sites');
  });

  test('the shutdown function awaits nothing', () {
    final body = _bodyOf(code['bin/main.dart']!, 'void _shutdown(');
    expect(body, isNotEmpty, reason: 'there must be one shutdown function');
    // The keyword, not the substring. `unawaited(…)` contains the letters and
    // means the exact opposite — it is the marker that says this call is
    // deliberately not waited on — and a scan that failed on it would push the
    // next person towards a bare fire-and-forget call with no marker at all,
    // which is the thing that is actually hard to review. `\bawait\b` still
    // catches every real await, including `await for`.
    expect(RegExp(r'\bawait\b').hasMatch(body), isFalse,
        reason: 'an awaited teardown is the stall; the whole point is that '
            'this function cannot block');
    expect(body, contains('exit(0)'));
    // The signature carries half the promise. `Future<void>` would let a
    // caller `await _shutdown(...)`, which is the stall arriving from the call
    // site instead of from the body — and it would compile.
    expect(code['bin/main.dart'], isNot(contains('Future<void> _shutdown(')),
        reason: 'nothing may be able to wait on this function');
  });

  test('the kill comes first, and the drain announcement after it', () {
    // Rig probe P9 added a second statement to this path, and the ORDER is the
    // safety property: `pipe.shutdown()` is what stops a dying process driving
    // the plant, and it must not queue behind a courtesy to whoever is
    // watching. An announcement first would also be an announcement that could
    // throw before the kill ran.
    final body = _bodyOf(code['bin/main.dart']!, 'void _shutdown(');
    final kills = 'pipe.shutdown()'.allMatches(body).map((m) => m.start);
    final announces =
        'announceDraining()'.allMatches(body).map((m) => m.start);
    expect(kills, isNotEmpty,
        reason: 'the acquisition workers must still be killed here');
    expect(announces, isNotEmpty,
        reason: 'and the panels must still be told this was deliberate');
    // EVERY kill before EVERY announce, not "the first of each". An earlier
    // `pipe.shutdown()` on some other branch would otherwise satisfy a
    // first-occurrence comparison while the real path announced first — a
    // mutation that swapped the two was written and did exactly that.
    expect(kills.reduce((a, b) => a > b ? a : b),
        lessThan(announces.reduce((a, b) => a < b ? a : b)),
        reason: 'the drain announcement must come after the kill: killing the '
            'workers is the part that cannot be skipped, and everything after '
            'it is a courtesy to the panels');
  });

  test('the deferred exit is a bounded count of event-loop turns, not a '
      'duration somebody picked', () {
    // AMENDED BY 13-14, deliberately, and the ban got wider rather than
    // narrower. What this pin used to require was the literal
    // `Timer(Duration.zero, () => exit(0))` — exactly one turn. That shape
    // shipped, and the rig's second run proved it delivers nothing over
    // `wss://`: a SecureSocket needs several rounds of the event loop to
    // encrypt and write what a plain socket takes in the round it is handed,
    // and the plant dials nothing but wss. The suite could not see it because
    // `drain_close_test.dart` only measured `ws://` on loopback; it now has a
    // TLS arm, and a `oneturn` arm that pins the old shape still failing.
    //
    // The hazard the pin was written for is UNCHANGED and still banned: a
    // wall-clock deferral. `Duration(milliseconds: 50)` would work here, would
    // read as reasonable, and is the exact shape the 5.76 s stall came in — a
    // shutdown budget with a number nobody can argue with. So the new shape has
    // to be measurably not that: a hard-capped count of `Duration.zero` yields,
    // where nothing a peer, a socket or a config does can add one turn. A 1 ms
    // timer failed six times out of six on the rig-equivalent fixture while
    // four zero-duration turns — far less than a millisecond of wall clock —
    // succeeded six out of six. It is turns the flush needs, and a clock buys
    // them only by accident.
    final body = _bodyOf(code['bin/main.dart']!, 'void _shutdown(');
    expect(body, contains('settleDrain()'),
        reason: 'the exit is scheduled behind the measured turn budget in '
            'RelayServer.settleDrain, not behind a hand-rolled deferral here');

    // The ban, widened: any timed thing with a number in it, however it is
    // spelled. The old regex only caught `Timer(Duration(`, so the very fix
    // that was tempting after the rig run — `Future.delayed(Duration(
    // milliseconds: 50))` — would have walked straight past it.
    final wallClock = RegExp(
        r'(Timer|Future\.delayed|Future<void>\.delayed)\(\s*(?:const\s+)?'
        r'Duration\(');
    expect(wallClock.hasMatch(body), isFalse,
        reason: 'a Duration with a number in it on the shutdown path is a '
            'wait, and this path may not wait for anything');
    expect(body, isNot(contains('sleep(')),
        reason: 'and a synchronous sleep is worse than a timer, not better: it '
            'blocks the isolate, so it denies the flush the very event-loop '
            'turns it is waiting for. Measured — 50 ms of sleep() delivered '
            '1006 three times out of three, having spent 56-62 ms doing it');
  });

  test('the turn budget the shutdown leans on is a const with a hard cap', () {
    // The other half of the amendment. Banning a Duration in `_shutdown` is
    // worth nothing if the budget it delegates to can grow a clock or an
    // unbounded loop, so the pin follows it into the package that owns it.
    // This is the arm that would still catch a genuine unbounded wait: a
    // `while (!settled)` there is a wait on something outside this process,
    // whatever it is spelled with.
    final relay = _stripComments(File('../tfc_relay_server/lib/src/'
            'relay_server.dart')
        .readAsStringSync());
    expect(relay, contains('static const int drainTurns'),
        reason: 'the bound must be a compile-time constant; a field, a config '
            'value or an argument is a bound somebody can move at runtime');
    final settle = _bodyOf(relay, 'static Future<void> settleDrain()');
    expect(settle, isNotEmpty);
    expect(settle, contains('turn < drainTurns'),
        reason: 'the loop must be counted against that constant');
    expect(settle, contains('Duration.zero'));
    expect(RegExp(r'Duration\(').hasMatch(settle), isFalse,
        reason: 'every yield is Duration.zero — this is a turn budget, and the '
            'moment one of them carries a number it is a wall-clock wait');
    expect(settle, isNot(contains('while')),
        reason: 'a conditional loop here is the unbounded wait this whole '
            'phase removed, whatever it is waiting on');
    expect(settle, isNot(contains('await socket')),
        reason: 'and nothing in the pump may await a peer');
  });

  test('the shutdown path reaches Isolate.kill(priority: Isolate.immediate)',
      () {
    // The chain, not a grep: main's shutdown calls the endpoint's, the
    // endpoint's calls every link's kill(), and the production link delegates
    // to the worker handle — which sets its no-respawn guard and then kills
    // the isolate immediately. The kill is spelled once, in the one place that
    // also owns the guard, because a second kill path that skipped the guard
    // would let the supervisor resurrect a worker we deliberately stopped.
    final endpointShutdown =
        _bodyOf(code['lib/core/pipe_main_endpoint.dart']!, 'void shutdown()');
    expect(endpointShutdown, contains('kill()'));
    // Word-boundary, not a substring scan: `unawaited(…)` CONTAINS the
    // letters `await` while meaning the exact opposite, so a plain
    // `contains('await')` passes a body that fires and forgets and fails a
    // body that is deliberately synchronous-with-unawaited. Found on
    // 2026-09-06 while chasing the TLS drain; two sibling pins had the same
    // defect and every one of them read stronger than it was.
    expect(endpointShutdown, isNot(matches(RegExp(r'\bawait\b'))));

    final handle = _stripComments(
        File('lib/core/data_acquisition_isolate.dart').readAsStringSync());
    expect(_bodyOf(handle, 'void kill()'),
        contains('kill(priority: Isolate.immediate)'));
  });
}

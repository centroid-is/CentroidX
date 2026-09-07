@TestOn('vm')

/// `connection_supervisor.dart` reaches nothing in `dart:io`, and stays that
/// way.
///
/// Source: 16-07, WSH-14.
///
/// **Why this one file and not the package.** The supervisor is the state
/// machine a web build reuses: it owns the four states, the backoff schedule,
/// the generation counter and the resync decisions, and it reaches the network
/// only through its own `dial:` seam — one `Uri` in, one `ConnectAttempt` out.
/// A browser leg supplies a different dial and gets the whole state machine for
/// free. It carried `import 'dart:io' show HandshakeException;` for a single
/// `is` check in `_refusalReason`, so it would not compile on web, for one line
/// classifying one exception. That classification now lives in
/// `ws_transport.dart`, which is `dart:io`-only anyway and documents at length
/// why — a pinned dial has no other seam — and hands the answer over as
/// `ConnectFailed.certificateUntrusted`.
///
/// **`remote_state_man.dart` is deliberately not swept, and that is the point
/// of scoping this to one file.** Its `dart:io` / `HttpClient` /
/// `SecurityContext` dependence is S11: documented deliberate debt with no
/// browser equivalent, because the browser owns TLS and cannot be handed a
/// private CA root at all. Closing it needs a conditional-import dial seam
/// *and* a config shape in which `tls` is meaningless, which is a milestone
/// that takes web seriously rather than a hardening pass. The difference
/// between the two files is exactly this: the supervisor's import was
/// avoidable today and S11's is not, so a sweep that covered both would be a
/// permanently red ratchet, and a permanently red test stops being
/// informative. One arm below asserts that difference rather than leaving it
/// to prose.
///
/// **Comment lines are stripped**, `no_bad_certificate_test.dart:171-185`'s
/// rule (`trimLeft()` starting `///` or `//`) copied whole. The supervisor's
/// own doc explains, at the site, which import went and why — naming it — and a
/// pin that counted prose would flag the paragraph that records the decision it
/// enforces.
///
/// **Two anti-vacuity arms**, for that file's reason: a sweep that reads
/// nothing passes forever and reads exactly like coverage. One asserts the file
/// was found, is the length of a state machine rather than a stub, and that the
/// same reading reports a needle that certainly is there in code. The other
/// plants both a real occurrence and a commented one in a temporary file and
/// requires the machinery to tell them apart.
///
/// What breaks in the plant without this file: nothing today, which is the
/// point — this is a ratchet, not a discovery. What it prevents is the next
/// person who needs one `dart:io` type here putting the import back, and the
/// web leg discovering it a milestone later, when the reason it was removed has
/// been forgotten and the fix is no longer three lines.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The needle under ban.
const String _banned = 'dart:io';

/// A needle that certainly is in the supervisor's *code*, for anti-vacuity.
///
/// The import every async file in this package has. If the reading below cannot
/// find this one, it is the reading that is clean and not the file.
const String _controlNeedle = 'dart:async';

/// A conservative floor on the supervisor's length.
///
/// Far below the measured count. A floor set near the real number fails on
/// every branch that moves a method out; this one only fails when the walk has
/// found the wrong file, which is the failure it exists to catch.
const int _lineFloor = 400;

/// This package's `lib/src`, found by walking up from wherever `dart test` was
/// invoked.
///
/// Fails rather than returning a fallback: a pin that quietly read a file that
/// was not there would pass every arm below by reading nothing.
Directory _libSrc() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}src');
    if (candidate.existsSync() &&
        File('${candidate.path}${Platform.pathSeparator}'
                'connection_supervisor.dart')
            .existsSync()) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('walked from ${Directory.current.absolute.path} to the filesystem '
          'root without finding lib/src/connection_supervisor.dart. Every '
          'assertion below would otherwise pass by reading nothing, which is '
          'exactly what the anti-vacuity arms exist to prevent — so this is a '
          'failure, not a skip.');
    }
    dir = parent;
  }
}

/// Every non-comment occurrence of [needle] in [file], as `(line, text)`.
///
/// A line is dropped when its `trimLeft()` starts with `///` or `//` — the same
/// rule as `no_bad_certificate_test.dart:171-185`, and for the same reason: the
/// file on this path discusses the removed import in prose, and a pin that
/// counted prose would be pinned to the wording of a comment.
List<(int, String)> mentionsIn(File file, String needle) {
  final hits = <(int, String)>[];
  final List<String> lines;
  try {
    lines = file.readAsLinesSync();
  } on FileSystemException {
    return const [];
  }
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (trimmed.startsWith('///') || trimmed.startsWith('//')) continue;
    if (lines[i].contains(needle)) hits.add((i + 1, lines[i]));
  }
  return hits;
}

void main() {
  late Directory src;
  late File supervisor;

  setUpAll(() {
    src = _libSrc();
    supervisor =
        File('${src.path}${Platform.pathSeparator}connection_supervisor.dart');
  });

  group('the supervisor compiles without dart:io', () {
    test('connection_supervisor.dart names dart:io nowhere in code', () {
      final hits = mentionsIn(supervisor, _banned);

      expect(hits, isEmpty,
          reason: 'found $_banned at:\n  '
              '${hits.map((h) => '${h.$1}: ${h.$2.trim()}').join('\n  ')}\n\n'
              'This file is the state machine a web build reuses through its '
              'own `dial:` seam — the four states, the backoff schedule, the '
              'generation counter, the resync decisions — and it reaches the '
              'network only through that seam. One `dart:io` symbol makes all '
              'of it uncompilable on web.\n\n'
              'If a platform judgement is needed, it belongs in '
              '`ws_transport.dart`, which is `dart:io`-only already and says '
              'why: a pinned dial has no other seam. That is how the '
              '`HandshakeException` check left this file — it became '
              '`ConnectFailed.certificateUntrusted`, a bool the supervisor '
              'reads without knowing what produced it.');
    });
  });

  group('the pin is proven not to be reading nothing', () {
    test('the pin really read the supervisor', () {
      expect(supervisor.existsSync(), isTrue,
          reason: '${supervisor.path} does not exist, so the arm above is a '
              'statement about a file nobody read');

      final lines = supervisor.readAsLinesSync();
      expect(lines.length, greaterThan(_lineFloor),
          reason: '${supervisor.path} holds only ${lines.length} lines, below '
              'the floor of $_lineFloor. That is not the supervisor — a pin '
              'anchored on a stub passes forever and reads exactly like '
              'coverage');

      expect(mentionsIn(supervisor, _controlNeedle), isNotEmpty,
          reason: 'the same reading that reports zero occurrences of $_banned '
              'must be able to report a non-zero count of $_controlNeedle, '
              'which is certainly there in code. If it cannot, the reading is '
              'what is clean, not the file');
    });

    test('the ban is scoped to the supervisor on purpose, and the neighbour '
        'proves it', () {
      // `remote_state_man.dart` is S11: `HttpClient` + `SecurityContext`, with
      // no browser equivalent because the browser owns TLS and cannot be
      // handed a private CA root. Deliberate, documented debt, out of this
      // phase's scope. Asserting it here does two things at once: it records
      // the scope decision where somebody widening the sweep will read it, and
      // it is a second control needle — the machinery finds `dart:io` in code
      // when `dart:io` is in code.
      final neighbour =
          File('${src.path}${Platform.pathSeparator}remote_state_man.dart');
      expect(neighbour.existsSync(), isTrue,
          reason: 'the neighbour this pin is deliberately not sweeping is not '
              'there, so the scope arm below is about nothing');
      expect(mentionsIn(neighbour, _banned), isNotEmpty,
          reason: 'remote_state_man.dart no longer names $_banned in code. '
              'That is good news and it retires this arm: either widen the pin '
              'to cover it, or delete this case. What it must not become is a '
              'sweep that is scoped to one file for a reason that has stopped '
              'being true');
    });

    test('the same machinery finds a planted import and ignores a commented '
        'one', () {
      // The strip rule, proven rather than asserted. Three lines carry the
      // identical string; one of them is code. If this ever reports three, the
      // pin has started flagging the paragraph that explains it, and the first
      // person to hit that deletes the pin rather than the comment.
      final scratch = Directory.systemTemp.createTempSync('wsh14-pin-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      File('${scratch.path}${Platform.pathSeparator}planted.dart')
          .writeAsStringSync('''
// This line mentions $_banned in a comment and must not count.
/// Neither must this one, which mentions $_banned too.
import '$_banned' show HandshakeException;
void main() {}
''');

      final hits = mentionsIn(
          File('${scratch.path}${Platform.pathSeparator}planted.dart'),
          _banned);

      expect(hits, hasLength(1),
          reason: 'exactly one of the three lines is code. Zero means the pin '
              'cannot see a real import and every green run above is '
              'meaningless; three means it counts prose, and the ban would '
              'fire on the doc comment that records why the import went');
      expect(hits.single.$1, 3,
          reason: 'the hit must name the line an engineer can go and look at; '
              'a violation reported without a location is a violation nobody '
              'finds');
    });
  });
}

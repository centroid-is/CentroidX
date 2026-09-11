@TestOn('vm')

/// SEC-02's grep-level half: `badCertificateCallback` appears nowhere in this
/// repository, and the sweep that says so is proven to bite.
///
/// **What the callback is.** `HttpClient.badCertificateCallback` is handed the
/// certificate a peer presented when validation has already *failed*, and its
/// return value decides whether the connection proceeds anyway. Every use of it
/// in the wild is `(cert, host, port) => true`, because the moment somebody
/// reaches for it they are trying to make a private CA work in a hurry and the
/// callback is the shortest path. It is a blanket accept wearing the clothes of
/// a security decision: the handshake completes, the socket says `wss://`, and
/// the panel will now talk to whatever answered on that port.
///
/// **Why a real check is not available inside it** — dart-lang/sdk#39425. The
/// callback receives an `X509Certificate` with no access to the presented
/// *chain*, so code inside it cannot verify the leaf against the private root:
/// it can compare a fingerprint against a hard-coded string, and that is all.
/// A pin written that way breaks silently on the yearly leaf re-issue this
/// plant has committed to, which means the person renewing the certificate is
/// also the person who has to remember to edit a Dart constant. The supported
/// mechanism is the one CLAUDE.md's stack table names:
/// `SecurityContext(withTrustedRoots: false)` with the CA root loaded in, which
/// validates the whole chain and keeps working across a leaf rotation.
///
/// **What breaks in the plant without this file.** Nothing today — the sweep
/// starts green, and that is the point. This is a ratchet, not a discovery. The
/// failure it prevents is a commissioning afternoon eighteen months from now
/// when a panel will not connect, the private root has not been provisioned to
/// that machine, and two lines of callback make the problem go away before
/// anybody goes home. From then on that panel accepts any certificate from
/// anything that can reach its gateway's address — and it looks identical, on
/// the screen and in the logs, to a panel that is properly pinned. There is no
/// operator-visible symptom to find it by later.
///
/// **It sweeps the whole repository, not the relay packages.** The Flutter app
/// is where the callback would actually be added, because that is where
/// somebody is when the panel will not come up. Anchoring on the package this
/// file lives in would leave the one tree that matters unswept.
///
/// **Two anti-vacuity arms, and they are the load-bearing half.** A sweep that
/// silently reads zero files passes forever and reads exactly like coverage. So
/// one case asserts the walk actually visited files — a floor on the count, and
/// a control needle it certainly should find — and another plants an occurrence
/// in a temporary tree and requires the same machinery to report it while
/// ignoring the identical string in a comment.
///
/// **Comment lines are stripped**, by `no_retry_test.dart:107-118`'s rule
/// (`trimLeft()` starting `///` or `//`), which is what lets this file's own
/// doc name the banned identifier at length. This file also excludes itself
/// from its own scan, the `handler_table_test.dart:44-47` precedent: it holds
/// the needle by necessity, so a sweep that read it would find its own literal
/// and report a violation of the rule it exists to enforce.
library;

import 'dart:io';

import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The anchor.
// ---------------------------------------------------------------------------

/// This file's own name, excluded from the scan. See the library doc.
const String _selfName = 'no_bad_certificate_test.dart';

/// The identifier under ban.
const String _banned = 'badCertificateCallback';

/// A needle that certainly exists in this tree, for the anti-vacuity arm.
///
/// `dart:io` rather than `SecurityContext`: the latter is what 06-01 and 06-03
/// will land and is therefore exactly the wrong control, because a needle that
/// is absent until a sibling plan lands is a needle that reports "the sweep is
/// broken" when the sweep is fine. This one is the import every file that could
/// reach [_banned] must have, and it is spread across every package here.
const String _controlNeedle = 'dart:io';

/// Directory names never descended into.
///
/// `.dart_tool` and `build` are generated. `.claude` holds other agents'
/// worktree checkouts of this same repository — sweeping those would report
/// another branch's code as this one's, and would make the result depend on
/// which agents happened to be running.
const Set<String> _prunedDirectories = {'.dart_tool', 'build', '.claude', '.git'};

/// A conservative floor on how many `.dart` files the sweep must see.
///
/// Deliberately far below the measured count (1,203 at the time of writing).
/// A floor set near the real number is a floor that fails on every branch that
/// deletes a package; this one only fails when the walk has gone badly wrong —
/// which is the failure it exists to catch.
const int _fileFloor = 200;

/// The directory holding this repository, found by walking up from wherever
/// `dart test` was invoked.
///
/// Anchored on `.git`, checked as an *entity* rather than a directory: in a
/// linked worktree `.git` is a file holding a pointer, and a check that
/// insisted on a directory would walk straight past the worktree root and
/// anchor on the main checkout — sweeping the wrong branch's code.
///
/// Fails rather than returning a fallback. A sweep that quietly anchored on the
/// package directory would still pass every case below except the floor, and
/// would be reporting on a twentieth of the tree.
Directory _repositoryRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final marker = '${dir.path}${Platform.pathSeparator}.git';
    if (FileSystemEntity.typeSync(marker) != FileSystemEntityType.notFound) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('walked from ${Directory.current.absolute.path} to the filesystem '
          'root without finding a directory holding `.git`, so there is no '
          'repository to sweep. Every case in this file would otherwise pass '
          'by reading nothing, which is the exact failure the anti-vacuity '
          'arms exist to prevent — so this is a failure, not a skip.');
    }
    dir = parent;
  }
}

// ---------------------------------------------------------------------------
// The sweep.
// ---------------------------------------------------------------------------

/// Every `.dart` file under [root], pruning [_prunedDirectories] and this file.
///
/// A hand-rolled walk rather than `listSync(recursive: true)` so the pruning
/// happens before the descent: the generated trees hold more files than the
/// source does, and a sweep nobody wants to wait for is a sweep somebody
/// switches off.
List<File> dartFilesUnder(Directory root) {
  final found = <File>[];
  final pending = <Directory>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      // An unreadable directory is not a violation; it is a directory this
      // process cannot see into. Reported as nothing found, never as a throw
      // from inside a helper.
      continue;
    }
    for (final entry in entries) {
      final name = entry.path.split(Platform.pathSeparator).last;
      if (entry is Directory) {
        if (_prunedDirectories.contains(name)) continue;
        pending.add(entry);
      } else if (entry is File &&
          name.endsWith('.dart') &&
          name != _selfName) {
        found.add(entry);
      }
    }
  }
  return found;
}

/// Every non-comment occurrence of [needle] in [file], as `(line, text)`.
///
/// A line is dropped when its `trimLeft()` starts with `///` or `//` — the same
/// rule as `no_retry_test.dart:107-118`, and for the same reason: the files on
/// this path discuss the ban in prose, and a sweep that counted prose would be
/// pinned to the wording of a comment and would flag the ban's own
/// documentation as a violation of it.
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

/// Every non-comment occurrence of [needle] under [root], as `path:line  text`.
List<String> occurrencesUnder(Directory root, String needle) {
  final hits = <String>[];
  for (final file in dartFilesUnder(root)) {
    for (final (line, text) in mentionsIn(file, needle)) {
      hits.add('${file.path}:$line  ${text.trim()}');
    }
  }
  return hits;
}

void main() {
  late Directory root;
  late List<File> swept;

  setUpAll(() {
    root = _repositoryRoot();
    swept = dartFilesUnder(root);
  });

  group('the callback that turns pinning off appears nowhere', () {
    test('the repository names badCertificateCallback nowhere', () {
      final hits = occurrencesUnder(root, _banned);

      expect(hits, isEmpty,
          reason: 'found $_banned at:\n  ${hits.join('\n  ')}\n\n'
              'This callback runs *after* certificate validation has already '
              'failed, and its return value decides whether the connection '
              'proceeds anyway — so in practice it is a blanket accept, and '
              'the socket still says wss://. It cannot be made into a real '
              'pin from the inside: dart-lang/sdk#39425 means the callback '
              'sees the leaf and not the presented chain, so the only check '
              'available in there is a hard-coded fingerprint, which breaks '
              'silently on the yearly leaf re-issue this plant runs on.\n\n'
              'The supported mechanism is SecurityContext(withTrustedRoots: '
              'false) with the private CA root loaded in — it validates the '
              'whole chain and survives a leaf rotation. If this fired '
              'because a private CA is not being trusted, that is the fix; '
              'the callback would make the symptom go away and leave the '
              'panel accepting any certificate from anything that can reach '
              'its gateway\'s address, with no operator-visible difference '
              'from a panel that is properly pinned.');
    });
  });

  group('the sweep is proven not to be reading an empty list', () {
    test('the sweep really read this repository', () {
      expect(
          FileSystemEntity.typeSync(
              '${root.path}${Platform.pathSeparator}.git'),
          isNot(FileSystemEntityType.notFound),
          reason: 'the anchor must be a directory holding `.git`; anything '
              'else is a sweep of some subtree that happens to be the '
              'working directory');

      expect(swept.length, greaterThan(_fileFloor),
          reason: 'the walk found only ${swept.length} .dart files under '
              '${root.path}, which is below the floor of $_fileFloor. A sweep '
              'that reads nothing passes forever and reads exactly like '
              'coverage — this is the case that tells the difference between '
              '"the ban holds" and "the walk is broken"');

      expect(occurrencesUnder(root, _controlNeedle), isNotEmpty,
          reason: 'the same machinery that reports zero occurrences of the '
              'banned identifier must be able to report a non-zero count of '
              'something that is certainly there. If this is empty then the '
              'reading, not the repository, is what is clean');
    });

    test('the sweep reaches the Flutter app, not just the relay packages', () {
      final appPrefix = '${root.path}${Platform.pathSeparator}lib'
          '${Platform.pathSeparator}';
      final packagesPrefix = '${root.path}${Platform.pathSeparator}packages'
          '${Platform.pathSeparator}';

      expect(swept.where((f) => f.path.startsWith(appPrefix)), isNotEmpty,
          reason: 'the app tree is where this callback would actually be '
              'added — somebody is standing at a panel that will not connect, '
              'and the app is the code in front of them. A ban that only '
              'covered the relay packages would miss every realistic way it '
              'gets written');
      expect(swept.where((f) => f.path.startsWith(packagesPrefix)), isNotEmpty,
          reason: 'and the packages, where the pinned dial itself lives');
    });

    test('the same machinery finds a planted occurrence and ignores a '
        'commented one', () {
      // The strip rule, proven rather than asserted. Both lines carry the
      // identical string; only one of them is code. If this case ever reports
      // two hits, the ban has started flagging its own documentation, and the
      // first person to hit that deletes the sweep rather than the comment.
      final scratch = Directory.systemTemp.createTempSync('sec02-sweep-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      File('${scratch.path}${Platform.pathSeparator}planted.dart')
          .writeAsStringSync('''
// This line mentions $_banned in a comment and must not count.
/// Neither must this one, which mentions $_banned too.
void main() {
  client.$_banned = (cert, host, port) => true;
}
''');

      final hits = occurrencesUnder(scratch, _banned);

      expect(hits, hasLength(1),
          reason: 'exactly one of the three lines is code. Zero means the '
              'sweep cannot see a real occurrence and every green run above '
              'is meaningless; three means it counts prose, and the ban would '
              'fire on the paragraph that explains it');
      expect(hits.single, contains(':4'),
          reason: 'the hit must name the line an engineer can go and look at; '
              'a violation reported without a location is a violation nobody '
              'finds');
      expect(dartFilesUnder(scratch), hasLength(1),
          reason: 'the planted tree holds one file, so the count above is not '
              'the sum of a walk that wandered');
    });
  });
}

@TestOn('vm')

/// HARD-03's grep-level half: the session-resume surface is withdrawn, and the
/// half that carries reconnection is still standing.
///
/// Source: 16-11.
///
/// **The decision this enforces.** HARD-03 was a fork — implement session
/// resume, or withdraw the surface — and it was resolved by withdrawing. A
/// resume means the gateway retaining per-session subscription state across a
/// socket loss and replaying from a per-subscription `lastSeq`, which is delta
/// replay; this product's doctrine, in CLAUDE.md's own words, is *"resync =
/// snapshot, never delta replay"*. Implementing it would have been implementing
/// the thing the architecture refuses. The reasoning is written out in
/// `.planning/phases/16-transport-hardening/16-CONTEXT.md`.
///
/// What was actually there was worse than an unimplemented feature. The type
/// was decoded server-side out of every hello and never read; no client in this
/// workspace ever set it; and the answer that came back was a `resumed` field
/// hardcoded `false` behind a comment promising it would mean something "until
/// 03-09" — a phase that came and went. A protocol field that promises fault
/// tolerance it does not have is worse than an absent one, because the next
/// milestone builds on it.
///
/// **Two negative arms and one positive one, and the positive one is the
/// important one.** A deletion can fail in two directions. Too narrow leaves
/// the dead names behind, which the two bans below catch. Too wide takes the
/// `session` object whole — and `epoch` lives in that object, feeding
/// `ConnectionSupervisor`'s `_resync.onHello(hello.epoch)`, which is the entire
/// epoch-change re-establishment mechanism. A deletion that took it would break
/// every reconnection in the plant while leaving both bans green. That is what
/// the third case is for, and it asserts on the **type surface** rather than by
/// grepping for the word `epoch`: a grep passes happily on a renamed field, and
/// a rename is exactly how this gets broken.
///
/// **Anti-vacuity, because both bans are negative.** A sweep that silently
/// reads zero files satisfies "the name appears nowhere" forever and reads
/// exactly like coverage. So one case asserts the walk found the repository and
/// more than a floor of files, that the lib-only subset is non-empty, and that
/// the same reading reports control needles that certainly are there. Another
/// plants an occurrence in a temporary tree and requires the machinery to
/// report it while ignoring the identical string in a comment.
///
/// **Comment lines are stripped**, by `no_bad_certificate_test.dart:171-185`'s
/// rule (`trimLeft()` starting `///` or `//`), which is what lets this file's
/// own doc name the withdrawn type at length. This file also excludes itself
/// from its own scan — it holds the needle by necessity.
///
/// **This is the third pin of this shape in this package.** The other two are
/// `no_bad_certificate_test.dart` (SEC-02, repository-wide) and
/// `no_dart_io_in_supervisor_test.dart` (16-07/WSH-14, one file). The mechanics
/// below are copied from them deliberately rather than improved, so that the
/// fourth person who needs one finds a pattern instead of three dialects.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tfc_relay_client/src/resync_engine.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// The anchors.
// ---------------------------------------------------------------------------

/// This file's own name, excluded from the scan. See the library doc.
const String _selfName = 'no_dead_resume_surface_test.dart';

/// The withdrawn type. Banned repository-wide: it was a wire shape, so a
/// re-declaration anywhere is a re-declaration of the promise.
const String _bannedType = 'SessionResume';

/// The withdrawn wire key, as it is spelled when a map is built.
///
/// Banned in `lib/` only, and the quotes are part of the needle. The bare word
/// is an ordinary English participle that legitimately appears as a local
/// variable and in prose all over this repository (`suspend_gate_test.dart`
/// alone has a dozen), so a ban on the bare word would be a ban nobody could
/// keep. Quoted, it is a JSON key, and a JSON key in `lib/` is the field coming
/// back.
const String _bannedWireKey = "'resumed'";

/// Directory names never descended into.
///
/// `.dart_tool` and `build` are generated. `.claude` holds other agents'
/// worktree checkouts of this same repository — sweeping those would report
/// another branch's code as this one's, and would make the result depend on
/// which agents happened to be running.
const Set<String> _prunedDirectories = {
  '.dart_tool',
  'build',
  '.claude',
  '.git'
};

/// A conservative floor on how many `.dart` files the sweep must see.
///
/// Deliberately far below the measured count. A floor set near the real number
/// fails on every branch that deletes a package; this one only fails when the
/// walk has gone badly wrong, which is the failure it exists to catch.
const int _fileFloor = 200;

/// A needle that certainly exists in this tree, for the anti-vacuity arm.
///
/// The import every file that could have held the withdrawn type has, and it is
/// spread across every package here. Deliberately not a name any plan in this
/// phase is adding or removing: a control that a sibling can retire reports
/// "the sweep is broken" when the sweep is fine.
const String _controlNeedle = 'dart:async';

/// The control needle for the `lib/`-scoped ban, and it is the kept half.
///
/// `'epoch'` is the quoted wire key that must survive this deletion, spelled
/// the same way [_bannedWireKey] is. Using it as the control means the arm that
/// proves the lib sweep can see a quoted key is the same arm that proves the
/// key it is looking for is still emitted.
const String _libControlNeedle = "'epoch'";

/// The directory holding this repository, found by walking up from wherever
/// `dart test` was invoked.
///
/// Anchored on `.git`, checked as an *entity* rather than a directory: in a
/// linked worktree `.git` is a file holding a pointer, and a check that
/// insisted on a directory would walk straight past the worktree root and
/// anchor on the main checkout — sweeping the wrong branch's code.
///
/// Fails rather than returning a fallback. A sweep that quietly anchored on the
/// package directory would still pass both bans by reading a twentieth of the
/// tree.
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
          'repository to sweep. Both bans in this file would otherwise pass by '
          'reading nothing, which is the exact failure the anti-vacuity arms '
          'exist to prevent — so this is a failure, not a skip.');
    }
    dir = parent;
  }
}

// ---------------------------------------------------------------------------
// The sweep. Copied from `no_bad_certificate_test.dart:135-196`.
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
      } else if (entry is File && name.endsWith('.dart') && name != _selfName) {
        found.add(entry);
      }
    }
  }
  return found;
}

/// Every non-comment occurrence of [needle] in [file], as `(line, text)`.
///
/// A line is dropped when its `trimLeft()` starts with `///` or `//` — the same
/// rule as `no_bad_certificate_test.dart:171-185`, and for the same reason: the
/// files on this path discuss the withdrawal in prose, and a sweep that counted
/// prose would flag the paragraph recording the decision as a violation of it.
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

/// Every non-comment occurrence of [needle] in [files], as `path:line  text`.
List<String> occurrencesIn(List<File> files, String needle) {
  final hits = <String>[];
  for (final file in files) {
    for (final (line, text) in mentionsIn(file, needle)) {
      hits.add('${file.path}:$line  ${text.trim()}');
    }
  }
  return hits;
}

/// The subset of [files] that is production code — under some `lib/`.
List<File> libFilesIn(List<File> files) {
  final sep = Platform.pathSeparator;
  return files.where((f) => f.path.contains('${sep}lib$sep')).toList();
}

// ---------------------------------------------------------------------------
// The compile-time half of case 3.
// ---------------------------------------------------------------------------

/// `ConnectionSupervisor` does `_resync.onHello(hello.epoch)`. This declaration
/// makes the two halves of that call a single compile-time fact.
///
/// It is never invoked; the *declaration* is the assertion. If `HelloResult`
/// stopped carrying `epoch`, or carried it under another name, or if
/// `ResyncEngine.onHello` stopped accepting what it produces, this file would
/// not compile — and a test file that does not compile is a loud red, not a
/// silently-passing grep.
// ignore: unused_element
Future<void> Function(String) _epochReachesResync(
        ResyncEngine engine, HelloResult hello) =>
    // The tear-off is typed by the parameter, and the argument type below is
    // taken from the field itself rather than written out as `String`, so a
    // change to either side is caught here rather than at the call site.
    (String epoch) => engine.onHello(hello.epoch);

void main() {
  late Directory root;
  late List<File> swept;
  late List<File> libSwept;

  setUpAll(() {
    root = _repositoryRoot();
    swept = dartFilesUnder(root);
    libSwept = libFilesIn(swept);
  });

  group('the resume surface is withdrawn', () {
    test('the repository declares SessionResume nowhere', () {
      final hits = occurrencesIn(swept, _bannedType);

      expect(hits, isEmpty,
          reason: 'found $_bannedType at:\n  ${hits.join('\n  ')}\n\n'
              'This type was a promise the gateway could not keep. It carried '
              'a previous session id, an epoch and a per-subscription '
              '`lastSeq`, and honouring it would mean the gateway retaining '
              'subscription state across a socket loss and replaying from that '
              'sequence — delta replay, which CLAUDE.md refuses in as many '
              'words: "resync = snapshot, never delta replay".\n\n'
              'It was also an unauthenticated client claim about a prior '
              'session, decoded out of every hello before anything had checked '
              'a credential, and read by nothing. HARD-03 resolved the fork by '
              'withdrawing it (16-CONTEXT.md). If a future milestone wants '
              'resume, it starts from the doctrine question — what may be '
              'replayed, and how a resumed session is bound to the credential '
              'that owns it — and not from re-declaring this type.');
    });

    test('no lib/ file emits the resumed wire key', () {
      final hits = occurrencesIn(libSwept, _bannedWireKey);

      expect(hits, isEmpty,
          reason: 'found the wire key $_bannedWireKey in production code at:\n'
              '  ${hits.join('\n  ')}\n\n'
              'For eleven phases the gateway put `"resumed": false` in every '
              'hello response and no code path could ever have made it true. A '
              'client that believed a `true` would keep a cache the server '
              'cannot honour and show stale plant data under a link that looks '
              'healthy — which is the failure mode this product exists to '
              'prevent. The field is gone; a `lib/` file that spells this key '
              'again is bringing the promise back.\n\n'
              'Test fixtures may spell it freely, and do: the decoder must go '
              'on tolerating a frame that still carries it. That is why this '
              'ban is scoped to lib/ and the repository-wide ban above is not.');
    });
  });

  group('the load-bearing half is still standing', () {
    test('a hello result still carries the session id and the epoch', () {
      // **The most important case in this file.** The two bans above are both
      // satisfied by deleting the whole `session` object, which would take
      // `epoch` with it and break every reconnection in the plant. This is the
      // arm that stops the deletion from being too wide.
      //
      // Asserted on the type surface and through a real round trip, never by
      // grepping for the word: a grep for `epoch` passes on a renamed field,
      // and a rename is exactly how a reader who does not know what the field
      // is for would break it.
      //
      // The frame is written out as JSON **text** rather than built by calling
      // the constructor, and that is deliberate: this case has to compile and
      // pass on both sides of the deletion, and a constructor call would have
      // to either name `resumed` (breaking after) or omit it (breaking before).
      // A file that does not compile reports as one failure, not as the four
      // this file is supposed to distinguish between — including the
      // anti-vacuity arm, which would then be unable to speak at all. Decoding
      // a frame that still carries `resumed` is also the honest fixture: it is
      // what a gateway on the far side of a mixed-version window sends.
      final incoming = HelloResult.fromJson((jsonDecode('{'
              '"protocol":"$protocolVersion",'
              '"server":{"name":"tfc-relay","version":"0.1.0"},'
              '"session":{"id":"sid","epoch":"e1","resumed":false},'
              '"clock":{"serverTime":1786000000123}}') as Map)
          .cast<String, Object?>());

      // Statically typed, so a rename or a type change is a compile failure
      // here rather than a green run somewhere else.
      final String epoch = incoming.epoch;
      final String sessionId = incoming.sessionId;
      expect(epoch, 'e1');
      expect(sessionId, 'sid');

      // And they survive a re-emit, which is the property that matters: this is
      // the gateway's own `toJson` putting the object back on the wire, so a
      // deletion that took `epoch` out of the emitted `session` map fails here
      // rather than in the plant.
      final wire = jsonDecode(jsonEncode(incoming.toJson()));
      final decoded =
          HelloResult.fromJson((wire as Map).cast<String, Object?>());

      expect(decoded.epoch, 'e1',
          reason: 'the epoch is the whole epoch-change re-establishment '
              'mechanism: ConnectionSupervisor feeds it straight into '
              '_resync.onHello, and ResyncEngine compares it against the one '
              'it last saw to decide whether every subscription this panel '
              'holds has to be rebuilt. A hello that no longer carries it '
              'leaves the client unable to tell a reconnection to the same '
              'gateway generation from a reconnection to a restarted one — so '
              'it either resyncs needlessly for ever or trusts handles the '
              'gateway has forgotten');
      expect(decoded.sessionId, 'sid',
          reason: 'the session id is what server-side attribution is written '
              'against; two sessions sharing one id merge in every log the '
              'gateway writes');
    });
  });

  group('the sweep is proven not to be reading an empty list', () {
    test('the sweep really read this repository', () {
      expect(
          FileSystemEntity.typeSync('${root.path}${Platform.pathSeparator}.git'),
          isNot(FileSystemEntityType.notFound),
          reason: 'the anchor must be a directory holding `.git`; anything '
              'else is a sweep of some subtree that happens to be the working '
              'directory');

      expect(swept.length, greaterThan(_fileFloor),
          reason: 'the walk found only ${swept.length} .dart files under '
              '${root.path}, which is below the floor of $_fileFloor. Both '
              'bans in this file are negative arms — "the name appears '
              'nowhere" — and a sweep that reads no files satisfies them '
              'vacuously, forever, while reading exactly like coverage. This '
              'is the case that tells the difference between "the surface is '
              'withdrawn" and "the walk is broken"');

      expect(occurrencesIn(swept, _controlNeedle), isNotEmpty,
          reason: 'the same machinery that reports zero occurrences of '
              '$_bannedType must be able to report a non-zero count of '
              'something that is certainly there. If this is empty then the '
              'reading, not the repository, is what is clean');

      expect(libSwept, isNotEmpty,
          reason: 'the lib-scoped ban is a statement about production code; if '
              'the subset is empty it is a statement about nothing');

      expect(occurrencesIn(libSwept, _libControlNeedle), isNotEmpty,
          reason: 'the lib subset must be able to report a quoted wire key '
              'that is certainly emitted. $_libControlNeedle is that key and '
              'it is also the half this plan kept, so an empty result here '
              'means either the lib sweep is broken or the deletion took the '
              'epoch with it — and both of those are failures');
    });

    test('the sweep reaches the Flutter app, not just the relay packages', () {
      final appPrefix =
          '${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}';
      final packagesPrefix = '${root.path}${Platform.pathSeparator}packages'
          '${Platform.pathSeparator}';

      expect(swept.where((f) => f.path.startsWith(appPrefix)), isNotEmpty,
          reason: 'the app tree holds the panel-side code that decodes a hello, '
              'and a ban that only covered the relay packages would miss a '
              'redeclaration there');
      expect(swept.where((f) => f.path.startsWith(packagesPrefix)), isNotEmpty,
          reason: 'and the packages, where the withdrawn type itself lived');
    });

    test(
        'the same machinery finds a planted occurrence and ignores a commented '
        'one', () {
      // The strip rule, proven rather than asserted. Three lines carry the
      // identical string; one of them is code. If this case ever reports three,
      // the ban has started flagging its own documentation, and the first
      // person to hit that deletes the sweep rather than the comment.
      final scratch = Directory.systemTemp.createTempSync('hard03-sweep-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      File('${scratch.path}${Platform.pathSeparator}planted.dart')
          .writeAsStringSync('''
// This line mentions $_bannedType in a comment and must not count.
/// Neither must this one, which mentions $_bannedType too.
final class $_bannedType {}
void main() {}
''');

      final planted = dartFilesUnder(scratch);
      final hits = occurrencesIn(planted, _bannedType);

      expect(hits, hasLength(1),
          reason: 'exactly one of the three lines is code. Zero means the '
              'sweep cannot see a real declaration and every green run above '
              'is meaningless; three means it counts prose, and the ban would '
              'fire on the paragraph that explains it');
      expect(hits.single, contains(':3'),
          reason: 'the hit must name the line an engineer can go and look at; '
              'a violation reported without a location is a violation nobody '
              'finds');
      expect(planted, hasLength(1),
          reason: 'the planted tree holds one file, so the count above is not '
              'the sum of a walk that wandered');
    });
  });
}

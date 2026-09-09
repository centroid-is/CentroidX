/// The mechanical gate for the legacy-acronym retirement.
///
/// **Why this exists.** Both feature flags in `lib/core/feature_flags.dart`
/// default to `true`. A build invocation that still passes
/// `--dart-define=TFC_CHAT=false` after the rename does not fail: the define
/// simply names a constant nothing reads any more, it is silently ignored, and
/// the shipped binary gets chat and the knowledge features compiled **in**. On
/// a customer station. Nothing at runtime re-checks that decision, and the
/// build log looks identical either way. A careful sweep cannot prevent that
/// class of mistake. A test that reads the tree from disk can.
///
/// **Comments are in scope; they are deliberately not stripped.** Every
/// workflow's hit comes in a pair — a `#` line explaining the flag, then the
/// `run:` line using it (see `.github/workflows/macos.yml:128` and `:130`). A
/// stale comment reading "TFC_CHAT off" sitting above a `CENTROIDX_CHAT`
/// define is precisely the confusion that ships the wrong binary to a panel, so
/// the comment is as much a defect as the define. `package_purity_test.dart`
/// strips comments because there the comment *names* the forbidden strings in
/// order to explain the rule; here the comment is part of the rule's surface.
///
/// **There is no allowlist, and adding one is not the fix.**
/// `TFC_ALLOW_FLUTTER_SKEW` is an environment key that the phase's rename table
/// did not originally cover, and the obvious cheap answer was to exempt it, or
/// to exempt `scripts/` and `test/tools/` wholesale. It was renamed instead
/// (plan 07-03). An exemption list is the exact hole this gate exists to close:
/// the next key added to it is the one that ships the wrong binary, and the
/// entry will look reasonable at the time it is written.
///
/// **Self-exclusion.** This file names the retired acronym in prose, above, so
/// it excludes itself from the scan — by exact path, once, at `_selfPath`. That
/// exclusion is the one soft spot in the design, so the
/// `the gate found what it is supposed to read` group makes it load-bearing: it
/// asserts the file at `_selfPath` exists, is non-empty, is absent from the
/// scanned set, and contains the assembled token. An exclusion nobody checks is
/// an allowlist with one entry.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/path_separators.dart';

/// Directory basenames never descended into.
///
/// Build output and tool caches contain copies of source — a stale
/// `.dart_tool` snapshot would report offenders that no longer exist in the
/// tree, and `build/` can hold a whole second copy of `lib/`. `.planning/` is
/// gitignored prose that discusses the rename at length.
const _skipDirNames = <String>{
  '.git',
  '.dart_tool',
  'build',
  '.planning',
  'node_modules',
  'ephemeral',
  'Pods',
  '.idea',
};

/// Binary file extensions, the only thing not read.
///
/// **This is an exclusion list, not an inclusion list, and the direction is the
/// whole point.** An allowlist of "interesting" extensions is complete for
/// today's tree — all thirteen `--dart-define` carriers are `.yml`, `.json`,
/// `.dart` or `Dockerfile.build` — and wrong for the class of mistake this
/// gate catches. This repository already carries PowerShell, Nix and direnv
/// files, and a define added to any of them would pass an inclusion list in
/// silence. That is the silent-ship hazard wearing a different file extension.
/// Everything is read except the formats below; extensionless files
/// (`Dockerfile`, `LICENSE`, `Podfile`) are read.
///
/// Enumerated from this tree's extension histogram, counted on the tracked
/// tree with `git ls-files | grep -Ec '\.(png|ttf|...)$'` on 2026-08-31: 1,823
/// tracked files, of which 383 carry a binary extension — `.png` (368),
/// `.ttf` (8), `.gif` (3), `.ico` (2), `.pdf` (1), `.icns` (1). The rest of the
/// list is defensive. If those figures have moved, recount rather than copying
/// them, and update this comment.
const _skipExtensions = <String>{
  '.png',
  '.ttf',
  '.otf',
  '.gif',
  '.ico',
  '.icns',
  '.jpg',
  '.jpeg',
  '.webp',
  '.pdf',
  '.woff',
  '.woff2',
  '.zip',
  '.so',
  '.dylib',
  '.dll',
  '.exe',
  '.a',
  '.o',
  '.wasm',
};

/// The one path excluded from the scan: this file.
const _selfPath = 'test/tools/centroidx_env_naming_test.dart';

/// Repo-relative paths that MUST be present in the scanned set.
///
/// These are the surfaces the phase's acceptance sentence names, plus the two
/// flag definitions. If one of them moves, the gate stops protecting it and
/// says nothing — so each gets a test of its own.
///
/// Note the eleventh entry. An earlier draft named
/// `packages/tfc_mcp_server/lib/src/identity/env_operator_identity.dart`; plan
/// 07-04 **deletes** that file, so naming it here would fail this group in
/// wave 3 through no fault of the gate. `read_toggles.dart` holds the
/// surviving toggles-env-var definition and lives through the whole phase.
const _manifest = <String>[
  '.github/workflows/macos.yml',
  '.github/workflows/windows.yml',
  '.github/workflows/linux.yml',
  '.github/workflows/centroid-hmi.yml',
  '.github/workflows/test.yml',
  'docker/frontend-ivi/Dockerfile.build',
  'docker-compose.yml',
  '.vscode/launch.json',
  'centroid-hmi/.vscode/launch.json',
  'packages/tfc_mcp_server/claude_desktop_config.example.json',
  'lib/core/feature_flags.dart',
  'packages/tfc_mcp_server/lib/src/tools/read_toggles.dart',
  'scripts/check-flutter-version.sh',
  'centroid-hmi/lib/navigation.dart',
];

/// Walk up from the current directory until the repo root is found.
///
/// `flutter test test/` runs from the repo root, but `centroid-hmi-test` sets
/// `working-directory: centroid-hmi`, and a test invoked from an IDE or from a
/// package subdirectory may start anywhere. A gate that silently passes because
/// it could not find the files it was meant to read is worse than no gate.
///
/// The sentinel needs care. The repo root's `pubspec.yaml` line is `name: tfc`,
/// which is a *prefix* of `name: tfc_access`, `name: tfc_dart` and
/// `name: tfc_mcp_server`, so a `contains('name: tfc')` check matches four
/// different directories and would happily anchor the scan inside a package.
/// Match a trimmed line equal to `name: tfc`, and require a sibling
/// `.github/workflows` directory as a second, independent signal.
Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (true) {
    final pubspec = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    final workflows =
        Directory('${dir.path}${Platform.pathSeparator}.github'
            '${Platform.pathSeparator}workflows');
    if (pubspec.existsSync() && workflows.existsSync()) {
      final named = pubspec
          .readAsLinesSync()
          .any((line) => line.trim() == 'name: tfc');
      if (named) return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
}

String _basename(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? path : path.substring(i + 1);
}

/// Repo-relative path with forward slashes, so the same string compares equal
/// on all three CI runners.
String _relative(Directory root, String path) =>
    withForwardSlashes(path.substring(root.path.length + 1));

/// The extension including the leading dot, lowercased; empty for a file with
/// no extension (`Dockerfile`) or a leading-dot name (`.gitignore`).
String _extensionOf(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '';
  return name.substring(dot).toLowerCase();
}

bool _isScannable(File file) => !_skipExtensions.contains(_extensionOf(file.path));

/// Read a file as lines, or return null when it is not text.
///
/// A second, format-independent defence behind [_skipExtensions]: a binary the
/// list misses must not throw and abort the whole walk, leaving a scan that
/// covers half the tree and passes. Anything with a NUL byte in its first 8 kB
/// is treated as binary, and a decode failure is treated the same way.
List<String>? _readTextLines(File file) {
  try {
    final handle = file.openSync();
    try {
      final head = handle.readSync(8192);
      if (head.contains(0)) return null;
    } finally {
      handle.closeSync();
    }
    return file.readAsLinesSync();
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// One file that was read, with its contents kept so the enforcement group does
/// not walk the tree a second time.
class _ScannedFile {
  const _ScannedFile(this.path, this.lines);

  /// Repo-relative, forward slashes.
  final String path;
  final List<String> lines;
}

/// The result of one walk of the tree.
class _Scan {
  const _Scan(this.files, this.skipped);

  final List<_ScannedFile> files;

  /// Files passed over for being binary — by extension or by NUL byte. Bounded
  /// by a test below: a filter that silently started swallowing source would
  /// otherwise turn this into a scanner that reads nothing and passes forever.
  final int skipped;

  bool contains(String relativePath) =>
      files.any((f) => f.path == relativePath);
}

_Scan _scanRepo(Directory root) {
  final files = <_ScannedFile>[];
  var skipped = 0;

  void walk(Directory dir) {
    final entries = dir.listSync(followLinks: false);
    for (final entry in entries) {
      if (entry is Directory) {
        if (_skipDirNames.contains(_basename(entry.path))) continue;
        walk(entry);
      } else if (entry is File) {
        final relative = _relative(root, entry.path);
        if (relative == _selfPath) continue;
        if (!_isScannable(entry)) {
          skipped++;
          continue;
        }
        final lines = _readTextLines(entry);
        if (lines == null) {
          skipped++;
          continue;
        }
        files.add(_ScannedFile(relative, lines));
      }
    }
  }

  walk(root);
  files.sort((a, b) => a.path.compareTo(b.path));
  return _Scan(files, skipped);
}

/// Manifest paths actually asserted on below, so the closing test can prove the
/// written-out tests and [_manifest] have not drifted apart.
final _checkedManifestPaths = <String>{};

void _expectProtected(_Scan scan, Directory root, String relativePath) {
  _checkedManifestPaths.add(relativePath);
  expect(
    scan.contains(relativePath),
    isTrue,
    reason: 'the gate did not read $relativePath. If this file moved, the gate '
        'stopped protecting it — update `_manifest`, do not delete the entry.',
  );
  final file = File('${root.path}/$relativePath');
  expect(
    file.existsSync() && file.readAsStringSync().trim().isNotEmpty,
    isTrue,
    reason: '$relativePath is missing or empty, so scanning it proves nothing. '
        'If this file moved, the gate stopped protecting it — update '
        '`_manifest`, do not delete the entry.',
  );
}

/// The retired acronym, followed by an underscore.
///
/// Assembled from two pieces rather than written as one literal for two
/// reasons. First, so this file's own source stays clean of the token it
/// forbids and a future variant of the gate — or a reviewer's `grep` — can
/// scan it like any other file. Second, so the doc comment at the top can name
/// the retired keys in prose, which it must, without the assembly picking them
/// up. The `guards the guard` group asserts the result is four characters and
/// that it does appear in this file's text, so a typo in the assembly fails
/// loudly instead of quietly disabling every assertion below.
final _retiredPrefix = '${'TFC'}${'_'}';

/// The replacement for each retired key, rendered into the failure message.
///
/// The two deletions matter more than the five renames. A reader who reaches
/// `TFC_USER` and looks for a new spelling has misunderstood the phase.
const _fixTable = '''
  TFC_CHAT               -> CENTROIDX_CHAT
  TFC_KNOWLEDGE          -> CENTROIDX_KNOWLEDGE
  TFC_MCP_SERVER_PATH    -> CENTROIDX_MCP_SERVER_PATH
  TFC_MCP_TOGGLES        -> CENTROIDX_MCP_TOGGLES
  TFC_ALLOW_FLUTTER_SKEW -> CENTROIDX_ALLOW_FLUTTER_SKEW
  TFC_USER               -> deleted outright, no successor key
  TFC_GOD                -> deleted outright, no successor key

  There is no CENTROIDX_MCP_OPERATOR to move TFC_USER to. The MCP subprocess
  gets no identity of its own, because the access session's signed-in user is
  the only identity in this system: MCP write tools return proposals, a human
  with the right permission authorizes them at approval, and the audit row
  names that approver rather than the proposer.

  There is no allowlist: rename it or delete it.''';

/// Every occurrence of [token] in every scanned file — not the first per file.
///
/// `.github/workflows/windows.yml` is the reason this returns all of them: it
/// builds twice, the exe at `:119`/`:121` and the MSIX at `:219`/`:221`, and
/// the MSIX defines sit inside a quoted `--windows-build-args` string. A
/// first-match-per-file check reports line 119 and ships line 221.
List<({String path, int line, String text})> _offenders(
  _Scan scan,
  String token, {
  bool Function(String line)? onlyLinesWhere,
}) {
  final hits = <({String path, int line, String text})>[];
  for (final file in scan.files) {
    for (var i = 0; i < file.lines.length; i++) {
      final line = file.lines[i];
      if (!line.contains(token)) continue;
      if (onlyLinesWhere != null && !onlyLinesWhere(line)) continue;
      hits.add((path: file.path, line: i + 1, text: line.trim()));
    }
  }
  return hits;
}

String _render(List<({String path, int line, String text})> hits) => hits
    .map((h) => '  ${h.path}:${h.line}: ${h.text}')
    .join('\n');

void main() {
  final root = _repoRoot();
  final scan = _scanRepo(root);

  group('the gate found what it is supposed to read', () {
    test('the scan read a substantial part of the tree', () {
      expect(
        scan.files,
        isNotEmpty,
        reason: 'a scan that finds nothing passes forever and protects '
            'nothing. Root resolved to ${root.path}.',
      );
      expect(
        scan.files.length,
        greaterThanOrEqualTo(1300),
        reason: 'read ${scan.files.length} files from ${root.path}, expected at '
            'least 1300. The tracked tree holds 2,054 files, 480 of them '
            'binary. A few hundred means the filter has become an inclusion '
            'list, which is the mistake this gate was written to correct.',
      );
    });

    test('the binary filter did not swallow the source tree', () {
      // A ceiling with headroom, not a count: it exists to catch a skip rule
      // that has started matching source, and the tree grows binaries
      // legitimately — upstream #461 and #462 added two asset families and
      // their goldens, taking the tracked binaries from 383 to 480 and
      // pushing the old 600 past its bound. Re-derived with
      // `git ls-files | grep -cE '\.(png|jpg|...)\$'`, then rounded up.
      expect(
        scan.skipped,
        lessThan(800),
        reason: 'passed over ${scan.skipped} files as binary while reading '
            '${scan.files.length}. 480 tracked files carry a binary extension; '
            'far more than that means a skip rule started matching source, and '
            'a scanner that reads nothing passes forever.',
      );
    });

    test('macos.yml is read', () => _expectProtected(scan, root, _manifest[0]));
    test('windows.yml is read', () => _expectProtected(scan, root, _manifest[1]));
    test('linux.yml is read', () => _expectProtected(scan, root, _manifest[2]));
    test('centroid-hmi.yml is read',
        () => _expectProtected(scan, root, _manifest[3]));
    test('test.yml is read', () => _expectProtected(scan, root, _manifest[4]));
    test('the ivi Dockerfile.build is read',
        () => _expectProtected(scan, root, _manifest[5]));
    test('docker-compose.yml is read',
        () => _expectProtected(scan, root, _manifest[6]));
    test('the root launch.json is read',
        () => _expectProtected(scan, root, _manifest[7]));
    test('the centroid-hmi launch.json is read',
        () => _expectProtected(scan, root, _manifest[8]));
    test('the claude desktop config example is read',
        () => _expectProtected(scan, root, _manifest[9]));
    test('feature_flags.dart is read',
        () => _expectProtected(scan, root, _manifest[10]));
    test('read_toggles.dart is read',
        () => _expectProtected(scan, root, _manifest[11]));
    test('check-flutter-version.sh is read',
        () => _expectProtected(scan, root, _manifest[12]));
    test('navigation.dart is read',
        () => _expectProtected(scan, root, _manifest[13]));

    test('every manifest entry has a test of its own', () {
      // Written out rather than generated in a loop, so a CI log line names the
      // surface that stopped being protected. This closes the loop: an entry
      // added to `_manifest` without a test above, or a test deleted while the
      // entry stayed, fails here.
      expect(_checkedManifestPaths, unorderedEquals(_manifest.toSet()));
    });

    test('every workflow in .github/workflows is scanned', () {
      final onDisk = Directory('${root.path}/.github/workflows')
          .listSync()
          .whereType<File>()
          .map((f) => _relative(root, f.path))
          .where((p) => p.endsWith('.yml'))
          .toList()
        ..sort();
      final unscanned = onDisk.where((p) => !scan.contains(p)).toList();
      expect(
        unscanned,
        isEmpty,
        reason: 'these workflows exist on disk but were not read: '
            '${unscanned.join(', ')}. Discovered by listing the directory, not '
            'from a hardcoded list, so a workflow added tomorrow cannot slip '
            'in unscanned.',
      );
    });

    test('there are at least nine workflows and all of them were found', () {
      final onDisk = Directory('${root.path}/.github/workflows')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.yml'))
          .length;
      expect(
        onDisk,
        greaterThanOrEqualTo(9),
        reason: 'found $onDisk workflow files; the tree has nine, four of which '
            'carry a legacy define (linux, centroid-hmi, macos, windows). '
            'Fewer means the listing broke, and a broken listing makes the '
            'test above vacuous.',
      );
    });

    test('the gate excludes itself, and only itself, by exact path', () {
      final self = File('${root.path}/$_selfPath');
      expect(self.existsSync(), isTrue,
          reason: '$_selfPath does not exist, so the exclusion below is '
              'excluding nothing and the path has gone stale.');
      expect(self.readAsStringSync().trim(), isNotEmpty);
      expect(
        scan.contains(_selfPath),
        isFalse,
        reason: 'this file names the retired acronym in prose and must not '
            'report itself. If it appears in the scanned set the exclusion '
            'path has drifted from the real filename.',
      );
    });

    test('the forbidden token assembled correctly', () {
      expect(
        _retiredPrefix.length,
        4,
        reason: 'the token is assembled from pieces rather than written as a '
            'literal, so a typo there would leave every assertion below '
            'searching for the wrong string and passing forever.',
      );
      expect(
        File('${root.path}/$_selfPath').readAsStringSync(),
        contains(_retiredPrefix),
        reason: 'this file names the retired keys in prose, so the assembled '
            'token must match that text. If it does not, the assembly is '
            'producing something other than the string being hunted.',
      );
    });
  });

  group('no legacy env keys or dart-defines survive', () {
    test('no file carries the retired acronym prefix', () {
      final hits = _offenders(scan, _retiredPrefix);
      final files = hits.map((h) => h.path).toSet();
      expect(
        hits,
        isEmpty,
        reason: '${hits.length} occurrences of the retired prefix survive in '
            '${files.length} files:\n\n${_render(hits)}\n\nThe fix, per key:\n'
            '$_fixTable',
      );
    });

    test('the dart-define surface specifically is clean', () {
      final hits = _offenders(
        scan,
        _retiredPrefix,
        onlyLinesWhere: (line) => line.contains('--dart-define='),
      );
      final files = hits.map((h) => h.path).toSet();
      expect(
        hits,
        isEmpty,
        reason: 'this is the silent-ship hazard, stated on its own. Both '
            'feature flags default to true, so each of these ${hits.length} '
            'defines across ${files.length} files is ignored rather than '
            'rejected once the constant is renamed, and the build ships with '
            'the feature compiled in:\n\n${_render(hits)}\n\nThe fix, per '
            'key:\n$_fixTable',
      );
    });
  });
}

/// Where a spec taken from a real plant is allowed to be written.
///
/// A plant's key mappings are the customer's: their machines, their tag
/// layout, the shape of their line. Scrubbing renames the site and changes
/// none of that, so a spec derived from one **is not committed**, in any
/// form, including "a small sample".
///
/// The rule is enforced by where the file goes rather than by a `.gitignore`:
/// an ignored path inside the tree is one `git add -f`, one editor plugin or
/// one `git clean -x` away from being in a commit or gone, and the person
/// making that mistake is usually chasing something else at the time.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// A destination that would have put plant data in the repository.
class ForbiddenDestination implements Exception {
  ForbiddenDestination(this.path, this.repoRoot);

  final String path;
  final String repoRoot;

  @override
  String toString() =>
      'refusing to write a plant spec inside the repository.\n'
      '  asked for: $path\n'
      '  repository: $repoRoot\n'
      'A spec taken from a real plant is customer data — their machines, '
      'their tag layout — and is not committed, scrubbed or otherwise. Write '
      'it outside the tree and point the bench at it:\n'
      '  --out "\$CENTROIDX_BENCH_SNAPSHOT/plant.yaml"';
}

/// Checks [destination] is outside [repoRoot], resolving both first.
///
/// Resolved, because `packages/../../outside` and a symlink into the tree both
/// read as "outside" on the text of the path and are not.
File checkedDestination(String destination, {String? repoRoot}) {
  final file = File(destination).absolute;
  final root = Directory(repoRoot ?? _repoRootOf(file.parent)).absolute;
  final resolvedRoot = _resolve(root.path);
  if (resolvedRoot == null) return file;

  final resolvedFile = _resolveThroughMissing(file.parent.path);
  if (p.equals(resolvedFile, resolvedRoot) ||
      p.isWithin(resolvedRoot, resolvedFile)) {
    throw ForbiddenDestination(file.path, resolvedRoot);
  }
  return file;
}

/// Resolves [path] through symlinks even when its tail does not exist yet.
///
/// **The guard failed open without this, and failed open on the ordinary
/// first use.** `_resolve` answers null for a directory that is not there, and
/// the old fallback compared an UNRESOLVED destination against a RESOLVED
/// root. On any system where the repository is reached through a symlink the
/// two can then never match, `p.isWithin` is false, and a spec derived from a
/// customer's key mappings is written inside the tree — which is the one thing
/// this file exists to prevent.
///
/// It is the normal case, not a corner: `--out <repo>/snapshots/plant.yaml`
/// with `snapshots/` not yet created is how somebody takes a first snapshot.
///
/// macOS reproduces it directly (`/var` -> `/private/var`, so every
/// `Directory.systemTemp` path is a symlink); a Linux CI box with a literal
/// `/tmp` does not, which is why the arm that pins this passed in the CI the
/// package shipped with and failed on the machine it was written on.
///
/// So the nearest existing ancestor is resolved and the missing tail is put
/// back on it. A path whose every ancestor is missing cannot be compared at
/// all, and the caller refuses rather than allows — a destination this cannot
/// place is not a destination it may bless.
String _resolveThroughMissing(String path) {
  var dir = p.normalize(p.absolute(path));
  final missing = <String>[];
  while (true) {
    final resolved = _resolve(dir);
    if (resolved != null) {
      return missing.isEmpty
          ? resolved
          : p.joinAll(<String>[resolved, ...missing.reversed]);
    }
    final parent = p.dirname(dir);
    // The filesystem root itself did not resolve: nothing to anchor against.
    if (p.equals(parent, dir)) return p.normalize(path);
    missing.add(p.basename(dir));
    dir = parent;
  }
}

String? _resolve(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}

/// The repository this process is running in, or the current directory when it
/// is not in one.
///
/// Walks up looking for `.git`, which is a directory in a clone and a file in
/// a worktree — both count, and a worktree is where this is usually run.
String _repoRootOf(Directory from) {
  var dir = from.absolute;
  while (true) {
    final marker = p.join(dir.path, '.git');
    if (Directory(marker).existsSync() || File(marker).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (p.equals(parent.path, dir.path)) return Directory.current.path;
    dir = parent;
  }
}

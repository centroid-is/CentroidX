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

  final resolvedFile = _resolve(file.parent.path) ?? p.normalize(file.parent.path);
  if (p.equals(resolvedFile, resolvedRoot) ||
      p.isWithin(resolvedRoot, resolvedFile)) {
    throw ForbiddenDestination(file.path, resolvedRoot);
  }
  return file;
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

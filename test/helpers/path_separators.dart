/// One thing: turn a path from `dart:io` into the spelling the structural
/// tests compare against.
///
/// Several tests in this suite walk the tree with `Directory.listSync` and then
/// compare what they find against path literals written by hand —
/// `'lib/providers/state_man.dart'`, `path.contains('/lib/')`,
/// `path.endsWith('.dart')`. Those literals are spelled with forward slashes,
/// because that is how a person writes a path and how the repository names its
/// own files. `File.path` is not: it carries the **platform** separator, so on
/// Windows the very same file comes back as `lib\providers\state_man.dart` and
/// every one of those comparisons is false.
///
/// **The dangerous failure is the quiet one.** A sweep that matches nothing
/// does not go red — it agrees with whatever it was asked. A census phrased as
/// `expect(offenders, isEmpty)` passes by finding no files at all; a
/// `where(...)` that filters `packages` down to `lib/` keeps zero files and
/// then reports that no package violates the rule. The test still runs, still
/// prints a green tick, and has read nothing. That is worse than a loud
/// failure, because the tick is taken as a guarantee. Several scans in this
/// repo carried exactly that bug, including ones guarding owner hard
/// requirements.
///
/// So: normalise at the point the string is minted — the moment it comes off
/// `entity.path` and before it is compared, filtered, or used as a map key —
/// and normalise *every* such point in a file. The recurring mistake is not
/// forgetting the call entirely; it is the half-normalised file, where the
/// walk is normalised and the exemption lookup fourteen lines further down is
/// not. A named call is visible in review in a way an inline `replaceAll` is
/// not: if you are reading a scan and see a bare `entity.path` next to a
/// [withForwardSlashes] one, that is the bug.
///
/// Anti-vacuity floors (`expect(visited, greaterThan(100))`) are the second
/// half of the defence and are not a substitute for this one: a floor written
/// in terms of files *visited* is satisfied by a walk that visits everything
/// and matches nothing.
library;

/// [path] with every backslash replaced by a forward slash.
///
/// A no-op on macOS and Linux, where `File.path` already uses `/`. See the
/// library doc above for why calling it anyway is not optional.
String withForwardSlashes(String path) => path.replaceAll(r'\', '/');

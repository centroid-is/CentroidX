/// There is exactly one of each access store, and it lives in `tfc_dart`.
///
/// Phase 17's constitution is Jón's ruling of 2026-09-06: *"I dont want
/// duplication, and I would like that there would be one master access control
/// system, the websocket can build on top of that"*. Plan 17-02 moved
/// `AccessTemplateStore`, `AccessAdminStore` and `AuditTrailStore` out of the
/// app's `lib/core/` and into `packages/tfc_dart/lib/core/access/` so the
/// backend serves **the same class** the panel calls, rather than a second
/// implementation of one policy.
///
/// A second implementation would not be a duplicated file. It would be a
/// backend copy that re-derived the `users` gate, the deny-row-before-throw
/// ordering, and the last-`users`-holder invariant `AccessRepository` evaluates
/// inside its own transaction — and the two would drift on exactly those. This
/// suite is the pin that stops one being written.
///
/// ## Why three arms and not one
///
/// A grep for `class AccessAdminStore` is the obvious pin and it is the
/// weakest: **a pattern derived from the old spelling cannot see a renamed
/// copy.** Somebody writing `final class BackendRoleAdmin` in
/// `tfc_relay_server` has duplicated the policy and defeated a name grep
/// completely. So the arms escalate, each one blind to a rename the one below
/// it would have caught:
///
/// 1. **the class name** — catches a literal second copy;
/// 2. **the gate constant** — catches a copy renamed at the class but still
///    naming its own `AccessGroup.users` gate;
/// 3. **the write surface** — catches a copy renamed at the class *and* the
///    constant that still issues Drift writes against the authorization
///    tables. That is the arm that is about identity rather than spelling: a
///    second implementation of this policy has to write these tables, whatever
///    it calls itself.
///
/// Each arm carries the same anti-vacuity half: the sweep must have visited
/// [_kMinimumFilesVisited] files. A broken glob finds no second copy for the
/// same reason it finds no first one, and would otherwise pass green forever.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The roots `scripts/sweep-write-paths.sh` searches, and for the same reason:
/// a write path is a write path whichever process runs it, so a copy hidden in
/// a relay package must be as visible here as one in `lib/`.
const List<String> _kRoots = [
  'lib',
  'centroid-hmi/lib',
  'demo',
  'packages',
];

/// The floor the sweep must clear before any "exactly one" claim is believed.
///
/// Measured 2026-09-07: 354 files under the three app roots and 341 under
/// `packages/*/lib`, 695 in total. Two hundred is well under that and well
/// over anything a broken glob would return, which is the only property the
/// number needs.
const int _kMinimumFilesVisited = 200;

/// Where the one copy of each store lives after plan 17-02.
const String _kAccessDir = 'packages/tfc_dart/lib/core/access';

/// Every `.dart` file under the sweep roots, as repository-relative paths.
///
/// `packages` is walked whole and then filtered to `lib/`, which is how the
/// shell script's `packages/*/lib` glob behaves and what keeps a package's own
/// `test/` out of the count.
List<String> _sweptFiles() {
  final files = <String>[];
  for (final root in _kRoots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      // `/`-normalised at the source: `File.path` uses the platform
      // separator, so on Windows `contains('/lib/')` matched nothing and this
      // scan silently swept ZERO package files — the worst failure a census
      // can have, because an empty sweep agrees with every claim.
      final path = entity.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart')) continue;
      if (root == 'packages' && !path.contains('/lib/')) continue;
      files.add(path);
    }
  }
  return files;
}

/// The file's source with comments removed.
///
/// The house rule: a bare count on an unfiltered file is self-invalidating the
/// moment somebody writes the token in a doc comment — and this file's own
/// library doc names all three classes, which is the demonstration.
String _uncommented(String path) {
  final withoutBlocks = File(path)
      .readAsStringSync()
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .map((line) {
        final idx = line.indexOf('//');
        return idx == -1 ? line : line.substring(0, idx);
      })
      .join('\n');
}

void main() {
  late List<String> files;
  late Map<String, String> sources;

  setUpAll(() {
    files = _sweptFiles();
    sources = {for (final f in files) f: _uncommented(f)};
  });

  test('the sweep visited enough files to be believed', () {
    expect(
      files.length,
      greaterThan(_kMinimumFilesVisited),
      reason: 'run this suite from the repository root. Every "exactly one" '
          'below is satisfied by a sweep that visited nothing, so this arm is '
          'the one that makes the other three able to fail at all.',
    );
  });

  // ---------------------------------------------------------------------------
  // Arm 1 — the class name
  // ---------------------------------------------------------------------------

  group('exactly one declaration of each store class, in tfc_dart', () {
    for (final entry in const {
      'AccessTemplateStore': '$_kAccessDir/access_template_store.dart',
      'AccessAdminStore': '$_kAccessDir/access_admin_store.dart',
      'AuditTrailStore': '$_kAccessDir/audit_trail_store.dart',
    }.entries) {
      test('${entry.key} is declared once, at ${entry.value}', () {
        expect(files.length, greaterThan(_kMinimumFilesVisited));

        final pattern = RegExp(r'(^|\s)class\s+' + entry.key + r'\b');
        final declaring = sources.entries
            .where((e) => pattern.hasMatch(e.value))
            .map((e) => e.key)
            .toList()
          ..sort();

        expect(
          declaring,
          [entry.value],
          reason: 'Phase 17 moved this class into tfc_dart so the backend and '
              'the panel run one implementation. A second declaration is a '
              'second policy, and the two drift on the invariants that matter '
              'most — the deny row written before the throw, and the '
              'last-users-holder check evaluated inside the transaction.',
        );
      });
    }
  });

  // ---------------------------------------------------------------------------
  // Arm 2 — the gate constant, which survives a class rename
  // ---------------------------------------------------------------------------

  test('only the three moved files declare a users gate constant', () {
    expect(files.length, greaterThan(_kMinimumFilesVisited));

    // A top-level `const AccessGroup kSomething = AccessGroup.users;`. A copy
    // that renamed the class still has to name the group it gates on, and a
    // copy that named it inline instead is caught by arm 3.
    final pattern =
        RegExp(r'const\s+AccessGroup\s+(\w+)\s*=\s*AccessGroup\.users\s*;');
    final declaring = <String, List<String>>{};
    for (final entry in sources.entries) {
      final names =
          pattern.allMatches(entry.value).map((m) => m.group(1)!).toList();
      if (names.isNotEmpty) declaring[entry.key] = names;
    }

    expect(
      declaring,
      {
        '$_kAccessDir/access_template_store.dart': ['kAccessTemplateGroup'],
        '$_kAccessDir/access_admin_store.dart': ['kAccessAdminGroup'],
        '$_kAccessDir/audit_trail_store.dart': ['kAuditTrailGroup'],
      },
      reason: 'three constants, three files, and all three in tfc_dart. The '
          'third is not a third store gate and the distinction is worth the '
          'sentence: kAuditTrailGroup is the ROUTE gate\'s constant, declared '
          'beside the store on purpose so that '
          "kRaisedRoutes['/advanced/audit-trail'] and the store name one "
          'decision — AuditTrailStore itself takes no session and cannot '
          'refuse anybody, which is what arm 3 checks from the other side. A '
          'fourth file declaring its own users gate is a second answer to '
          '"what does this require?", which is the question D-01 puts in '
          'AccessPolicy and nowhere else. This arm sees a copy that arm 1 '
          'cannot: renaming the class does not remove the gate it has to name.',
    );
  });

  // ---------------------------------------------------------------------------
  // Arm 3 — the write surface, which survives renaming both
  // ---------------------------------------------------------------------------

  test('only two files write the authorization tables', () {
    expect(files.length, greaterThan(_kMinimumFilesVisited));

    // Identity, not spelling: whatever a second implementation calls itself and
    // whatever it calls its gate, it has to reach these four tables through a
    // Drift write to do the job at all.
    final tables = RegExp(
        r'\b(accessTemplateTable|accessKeyBindingTable|appRole|appUser)\b');
    final writes = RegExp(r'\.(into|update|delete)\(');

    final writers = sources.entries
        .where((e) => tables.hasMatch(e.value) && writes.hasMatch(e.value))
        .map((e) => e.key)
        .toSet();

    expect(
      writers,
      {
        '$_kAccessDir/access_template_store.dart',
        '$_kAccessDir/access_repository.dart',
      },
      reason: 'access_template_store.dart writes access_template and '
          'access_key_binding; access_repository.dart writes app_role and '
          'app_user and owns the transaction the last-users-holder invariant '
          'is evaluated inside. Two files, and both in tfc_dart. The drift '
          'layer is deliberately not an exception here — measured 2026-09-07, '
          'neither database_drift.dart nor its generated half uses any of the '
          'three verbs, so naming them would have been an exception that '
          'widened the arm for nothing. A third name is a second writer of the '
          'authorization data, whatever it is called.',
    );
  });

  // ---------------------------------------------------------------------------
  // The app's side of the move: re-exports, not re-declarations
  // ---------------------------------------------------------------------------

  group('the app files left behind are exports and nothing else', () {
    for (final entry in const {
      'lib/core/access_template_store.dart': 'access_template_store.dart',
      'lib/core/access_admin_store.dart': 'access_admin_store.dart',
      'lib/core/audit_trail_store.dart': 'audit_trail_store.dart',
    }.entries) {
      test('${entry.key} re-exports rather than re-declaring', () {
        final file = File(entry.key);
        expect(file.existsSync(), isTrue,
            reason: 'the old path is kept so no call site changed and so a '
                'grep for it still lands somewhere true');

        final source = _uncommented(entry.key);
        expect(
          source,
          contains("export 'package:tfc_dart/core/access/${entry.value}';"),
          reason: 'the app reaches the moved class through an export. A file '
              'here that declared anything would be the second copy the arms '
              'above exist to refuse.',
        );
        expect(
          RegExp(r'(^|\s)class\s').hasMatch(source),
          isFalse,
          reason: 'an export file that grew a class is how a second copy '
              'starts — one convenience wrapper at a time.',
        );
      });
    }
  });
}

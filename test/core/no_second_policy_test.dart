/// One master access-control system, and it stays one.
///
/// Phase 17's constitution is Jón's ruling of 2026-09-06, recorded in
/// 17-CONTEXT.md and restated in the project's Constraints:
///
/// > *"I dont want duplication, and I would like that there would be one master
/// > access control system, the websocket can build on top of that, makes
/// > sense?"*
/// > *"Authorisation is enforced server-side. This is hard requirement."*
///
/// The success condition of the phase was never "the relay has RBAC too". It
/// was "there is exactly one access-control system, and the relay is a consumer
/// of it." A second policy model — even a correct one — fails the phase. That is
/// a property of the whole tree, not of any one plan, and a property of the tree
/// with no test is a property that decays: the next twelve months of edits will
/// reintroduce a second `enum Role`, a second identity axis, or a relay-side
/// group grade one convenience at a time unless something on every PR refuses
/// it. This file is that something. It runs in the app's suite (`test/core/`)
/// rather than in a package, so it sweeps `lib/`, `centroid-hmi/lib/`, `demo/`
/// and `packages/*/lib/` together and runs on every PR.
///
/// Each arm names the clause of the constitution it enforces, so a future reader
/// knows whether they are looking at a rule or a habit. `.planning/PROJECT.md`
/// is gitignored and absent from a fresh worktree; the clause quoted above is
/// the same one PROJECT.md's Constraints section restates, sourced here from
/// 17-CONTEXT.md and CLAUDE.md, both of which are in the tree.
///
/// ## Anti-vacuity is not optional
///
/// Every "exactly one" is satisfied by a sweep that visited nothing, so arm 9
/// asserts the sweep saw more than [_kMinimumFilesVisited] files AND found a
/// positive control — the one legitimate `enum AccessGroup`, at its expected
/// path. A pin that sweeps nothing passes every other arm; this file's whole
/// value is that it keeps passing, truthfully, for years.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The roots swept, matching `scripts/sweep-write-paths.sh` and
/// `no_duplicate_access_stores_test.dart`: a second policy is a second policy
/// whichever process it hides in.
const List<String> _kRoots = ['lib', 'centroid-hmi/lib', 'demo', 'packages'];

/// The floor the sweep must clear before any "exactly one" claim is believed.
/// `no_duplicate_access_stores_test.dart` measured ~695 files under these roots
/// on 2026-09-07; 200 is well under that and well over a broken glob's zero.
const int _kMinimumFilesVisited = 200;

/// Where the one master vocabulary lives.
const String _kAccessGroupFile =
    'packages/tfc_access/lib/src/access_group.dart';

/// Every `.dart` file under the roots, repository-relative — `packages` walked
/// whole then filtered to `lib/`, exactly as the shell glob `packages/*/lib`
/// behaves, so a package's own `test/` stays out of the count.
List<String> _sweptFiles() {
  final files = <String>[];
  for (final root in _kRoots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      // `/`-normalised at the source. `File.path` uses the platform
      // separator, so on Windows `contains('/lib/')` matched NOTHING and this
      // scan swept zero package files — and arm 9's anti-vacuity floor is
      // written in terms of files visited, so the whole gate for the
      // one-master-policy law would have passed by sweeping nothing. Of the
      // several scans carrying this bug tonight, this is the one that mattered
      // most: it guards an owner hard requirement.
      final path = entity.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart')) continue;
      if (root == 'packages' && !path.contains('/lib/')) continue;
      files.add(path);
    }
  }
  return files;
}

/// A file's source with comments removed — the house rule: a bare count on an
/// unfiltered file is self-invalidating the moment somebody names the token in a
/// doc comment, and this file's own library doc names `enum Role` twice.
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

/// The files whose uncommented source matches [pattern], sorted.
List<String> _matching(Map<String, String> sources, RegExp pattern) =>
    (sources.entries.where((e) => pattern.hasMatch(e.value)).map((e) => e.key)
        .toList())
      ..sort();

void main() {
  late List<String> files;
  late Map<String, String> sources;

  setUpAll(() {
    files = _sweptFiles();
    sources = {for (final f in files) f: _uncommented(f)};
    // Reported, not merely asserted — arm 9 checks the number, and printing it
    // keeps the sweep's reach visible on every run.
    // ignore: avoid_print
    print('no_second_policy: swept ${files.length} .dart files under $_kRoots');
  });

  void requireVisited() =>
      expect(files.length, greaterThan(_kMinimumFilesVisited),
          reason: 'run this suite from the repository root; every "exactly one" '
              'below is vacuous against a sweep that visited nothing');

  // -------------------------------------------------------------------- arm 1
  // Constitution: "one master access control system". A second role vocabulary
  // is the most direct second policy — `enum Role { view, operate }` was the
  // relay's, deleted this phase.
  group('arm 1 — no second role vocabulary', () {
    test('no `enum Role` anywhere outside tfc_access', () {
      requireVisited();
      final declaring = _matching(sources, RegExp(r'\benum\s+Role\b'))
          .where((p) => !p.startsWith('packages/tfc_access/'))
          .toList();
      expect(declaring, isEmpty,
          reason: 'a bare `enum Role` is the deleted relay vocabulary returning. '
              'The one master vocabulary is AppRole/AccessRole in tfc_access; '
              'any other "one master access control system" (Jón, 2026-09-06)');
    });

    test('no enum names a Role vocabulary grading `operate` outside tfc_access',
        () {
      requireVisited();
      // An enum whose name ends in Role AND whose body reaches for `operate` is
      // a role grading a permission — a renamed second vocabulary the bare-name
      // arm cannot see. HmiColorRole/ChatRole/_RoleDeleteBlock name no `operate`
      // member and pass.
      final pattern = RegExp(
          r'enum\s+\w*Role\w*\s*(<[^>]*>)?\s*\{[^}]*\boperate\b[^}]*\}',
          dotAll: true);
      final declaring = _matching(sources, pattern)
          .where((p) => !p.startsWith('packages/tfc_access/'))
          .toList();
      expect(declaring, isEmpty,
          reason: 'an enum that both names itself a Role and grades `operate` is '
              'a second answer to "what may this actor do" — the question the '
              'constitution puts in one place');
    });
  });

  // -------------------------------------------------------------------- arm 2
  // "one master access control system": one identity axis. The deleted
  // `Identity { stationId, role }` was the relay's own; `StationIdentity`
  // (an AuthenticatedUser + station + session) is the one hit.
  test('arm 2 — no second identity axis: `class Identity` is gone, '
      'StationIdentity is the one that remains', () {
    requireVisited();
    final identity = _matching(sources, RegExp(r'\bclass\s+Identity\b'));
    expect(identity, isEmpty,
        reason: 'the relay\'s `class Identity { stationId, role }` was a second '
            'identity model; it was replaced by StationIdentity, which is an '
            'AuthenticatedUser from tfc_access plus the station');
    final station =
        _matching(sources, RegExp(r'\b(class|final class)\s+StationIdentity\b'));
    expect(station, ['packages/tfc_relay_server/lib/src/auth/identity.dart'],
        reason: 'StationIdentity is the credential-side identity and is '
            'declared once; a second declaration would be a second axis wearing '
            'the sanctioned name');
  });

  // -------------------------------------------------------------------- arm 3
  test('arm 3 — exactly one `enum AccessGroup`, in tfc_access', () {
    requireVisited();
    final declaring = _matching(sources, RegExp(r'\benum\s+AccessGroup\b'));
    expect(declaring, [_kAccessGroupFile],
        reason: 'AccessGroup is the master vocabulary of permissions. A second '
            'declaration — even identical — is two vocabularies that will drift '
            'the moment one gains a value: the seven-group count is asserted in '
            'tfc_access and nowhere else can answer it (D-01)');
  });

  // -------------------------------------------------------------------- arm 4
  test('arm 4 — the preference grading `kPrefAccessRules` is declared once', () {
    requireVisited();
    // The DECLARATION, not the many references: `... kPrefAccessRules =`.
    final declaring = _matching(
        sources, RegExp(r'\bkPrefAccessRules\s*='));
    expect(declaring, ['packages/tfc_access/lib/src/access_policy.dart'],
        reason: 'kPrefAccessRules grades every preference key — D-03 ruled the '
            'app\'s grading wins over the wire, so a second table is the §3.12 '
            'divergence returning in the place it bites most (key_mappings)');
  });

  // -------------------------------------------------------------------- arm 5
  test('arm 5 — the tag-write `operate` floor lives in one method, '
      'AccessPolicy.groupForTag', () {
    requireVisited();
    // The floor for a tag write is answered by exactly one method. A second
    // `groupForTag` — or any other method deciding a tag write against a group
    // — is the two-places state the constitution deletes. This is the clause
    // the ruling spells out by name ("use the pre-existing access level"), and
    // it was previously true in both the app and the relay.
    final declaring =
        _matching(sources, RegExp(r'\bAccessGroup\s+groupForTag\b'));
    expect(declaring, ['packages/tfc_access/lib/src/access_policy.dart'],
        reason: 'groupForTag is where "a tag write needs operate" is stated. A '
            'second declaration is a second floor, and the relay used to hold '
            'one (requireOperate); this phase deleted it so the app and the '
            'wire ask the same object');
  });

  // -------------------------------------------------------------------- arm 6
  test('arm 6 — AllVisibleOperatorWrites and requireOperate are gone', () {
    requireVisited();
    final allVisible = _matching(
        sources, RegExp(r'\b(class|mixin)\s+AllVisibleOperatorWrites\b'));
    expect(allVisible, isEmpty,
        reason: 'AllVisibleOperatorWrites was the relay KeyPolicy whose '
            'canWrite compared role == operate — the second tag-write policy. '
            'It was replaced by AccessPolicyKeyPolicy, which asks the master');
    final requireOperate =
        _matching(sources, RegExp(r'\brequireOperate\b'));
    expect(requireOperate, isEmpty,
        reason: 'requireOperate was the relay _OperateGate\'s method; the '
            'replacement asks _requireGroup against the master policy');
  });

  // -------------------------------------------------------------------- arm 7
  test('arm 7 — exactly one AuditSink interface', () {
    requireVisited();
    final declaring = _matching(sources,
        RegExp(r'\babstract\s+(interface\s+)?class\s+AuditSink\b'));
    expect(declaring, ['packages/tfc_access/lib/src/audit.dart'],
        reason: 'D-05 injects one AuditSink into RelayServer so the wire and '
            'the panel write the same audit_entry table. A second sink '
            'interface is a second trail, and a refusal recorded in only one is '
            'the guard nobody can audit afterwards');
  });

  // -------------------------------------------------------------------- arm 8
  test('arm 8 — no relay-side group literal: tfc_relay_server names no '
      'specific AccessGroup grade', () {
    requireVisited();
    // The relay decides "which identity is this" and asks the master "and may
    // it do X". It never names a specific group as a requirement. `AccessGroup`
    // as a TYPE is fine (it passes group sets around); `AccessGroup.values` (the
    // permissive-dev whole-set mint, D-07) is fine. A specific grade —
    // AccessGroup.operate/users/configure/administer/setpoints/view — is the
    // relay grading, which is what Phase 17 deleted.
    final grade = RegExp(
        r'\bAccessGroup\.(operate|users|configure|administer|setpoints|view)\b');
    final relayGraders = sources.entries
        .where((e) => e.key.startsWith('packages/tfc_relay_server/lib/'))
        .where((e) => grade.hasMatch(e.value))
        .map((e) => e.key)
        .toList()
      ..sort();
    expect(relayGraders, isEmpty,
        reason: 'a relay lib file naming a specific AccessGroup grade is the '
            'relay answering "what does this require?" itself — the second '
            'policy the constitution forbids. It grants the whole set for the '
            'permissive dev default (AccessGroup.values) and otherwise asks the '
            'master: $relayGraders');
  });

  // -------------------------------------------------------------------- arm 9
  test('arm 9 — the sweep is not vacuous: it visited enough files AND found '
      'the positive control', () {
    // The number: reported by setUpAll, asserted here.
    expect(files.length, greaterThan(_kMinimumFilesVisited),
        reason: 'a sweep that visited ${files.length} files passes every '
            '"exactly one" above trivially; this is the arm that makes the '
            'other eight able to fail at all');
    // The positive control: the one legitimate enum AccessGroup is actually
    // present at its expected path, so the sweep is demonstrably reaching real
    // source and not an empty read of the wrong directory.
    expect(sources.containsKey(_kAccessGroupFile), isTrue,
        reason: 'the master vocabulary file was not in the swept set, so the '
            'sweep is not reaching tfc_access — every arm above is then '
            'asserting the absence of things in a place it never looked');
    expect(sources[_kAccessGroupFile], contains('enum AccessGroup'),
        reason: 'the positive control file exists but declares no '
            '`enum AccessGroup` — the one thing arm 3 counts must genuinely be '
            'there, or arm 3 is counting an empty set to one by luck');
  });
}

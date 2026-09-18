@TestOn('vm')

/// ACCESS-05 / ACCESS-06: the relay's parallel role vocabulary is deleted, and
/// what replaces it decides nothing.
///
/// Four properties, in the order the phase's constitution puts them:
///
///  1. **`enum Role` and `class Identity` are gone from this package's `lib`**,
///     pinned by greps that strip comments first. Phase 17's whole claim is
///     that there is exactly one access-control system; a second role
///     vocabulary sitting in `lib/src/auth/` is that claim being false, and a
///     grep is what keeps it from creeping back in as "just an enum".
///  2. **`StationIdentity` still cannot hold a credential.** The type it
///     replaces argued its own safety *structurally* — "it has two fields, and
///     neither is the token" — which is why the argument is worth a structural
///     test rather than a comment.
///  3. **`StationIdentity` still has value equality.** The revocation sweep
///     compares an identity against what the token file now says on every
///     reload; reference equality would answer "changed" for every session and
///     close the whole plant on the first reload.
///  4. **`toString()` names the station and the role and no group.** This type
///     is printed into logs, into close reasons and into refusals. A close
///     reason that enumerated what a station may do would publish the plant's
///     grading to whoever is watching the socket.
///
/// Without (1) the phase has added a second correct model, which CONTEXT says
/// fails the phase. Without (2) or (4) the type that is safe to print stops
/// being safe to print, silently.
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:tfc_access/tfc_access.dart';
import 'package:test/test.dart';
import 'package:tfc_relay_server/src/auth/identity.dart';

/// The package root, found by walking up from the test's working directory.
///
/// Throws rather than skipping when it cannot be found. A grep pin that
/// silently stops looking is a pin that passes forever — which is the exact
/// failure mode these arms exist to prevent for `Role`.
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: tfc_relay_server')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
      'could not find the tfc_relay_server package root from ${Directory.current.path}; '
      'the source sweep below would otherwise have visited nothing and passed');
}

/// Every `.dart` file under this package's `lib`, with comment lines removed.
///
/// The house rule (17-CONTEXT, `house_style`): a bare grep over an unfiltered
/// file self-invalidates the moment somebody writes the deleted token in a doc
/// comment explaining why it was deleted — which is exactly the comment a
/// careful author writes. Only whole comment lines are stripped, because that
/// is what the rule says and because a stripper clever enough to handle
/// trailing comments is a stripper that can be wrong.
Map<String, String> _libSourcesWithoutComments() {
  final root = Directory('${_packageRoot().path}/lib');
  final out = <String, String>{};
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final stripped = entity
        .readAsLinesSync()
        .where((line) {
          final trimmed = line.trimLeft();
          return !trimmed.startsWith('//');
        })
        .join('\n');
    out[entity.path] = stripped;
  }
  return out;
}

/// Files whose stripped source matches [declaration], by path.
List<String> _declaringFiles(
    Map<String, String> sources, RegExp declaration) =>
    sources.entries
        .where((e) => declaration.hasMatch(e.value))
        .map((e) => e.key)
        .toList()
      ..sort();

void main() {
  group('the parallel role vocabulary is deleted', () {
    test('enum Role is declared nowhere under lib', () {
      final sources = _libSourcesWithoutComments();

      expect(sources.length, greaterThan(20),
          reason: 'the anti-vacuity half, and it goes first: a sweep that '
              'visited two files would pass the assertion below by having '
              'looked nowhere. This package has dozens of libraries');

      expect(_declaringFiles(sources, RegExp(r'enum\s+Role\b')), isEmpty,
          reason: 'PROJECT.md\'s Constraints section names this type: a '
              '`Role` enum in the relay is a second role vocabulary beside '
              'the seven AccessGroups tfc_access already owns. The phase\'s '
              'success condition is not "the relay has RBAC too" — it is '
              '"there is exactly one access-control system, and the relay is '
              'a consumer of it". A second correct model still fails the '
              'phase');
    });

    test('class Identity is declared nowhere under lib', () {
      final sources = _libSourcesWithoutComments();

      expect(sources.length, greaterThan(20),
          reason: 'the same anti-vacuity half. Both arms read the tree, and '
              'both are worthless if the tree was not found');

      expect(_declaringFiles(sources, RegExp(r'class\s+Identity\b')), isEmpty,
          reason: '`Identity {stationId, role}` is a second identity axis for '
              'something tfc_access already models: '
              'AuthenticatedUser.stationAccount is "this identity is a panel, '
              'not a person, and its sessions never expire", schema v8. Two '
              'identity types is two places for a station to be described, '
              'and the audit trail can only carry one of them');
    });

    test('the sweep can find a declaration, so it is not blind', () {
      // The control for both arms above. Without it, a regex that matched
      // nothing anywhere — a typo in the pattern, a stripper that ate every
      // line — would pass them both.
      final sources = _libSourcesWithoutComments();

      expect(
          _declaringFiles(sources, RegExp(r'class\s+StationIdentity\b')),
          isNotEmpty,
          reason: 'the same mechanic that reports "no Role" must be able to '
              'report "yes StationIdentity". A sweep that answers empty for '
              'everything proves nothing about what it was asked');
    });
  });

  group('StationIdentity keeps the properties Identity was built for', () {
    test('it cannot hold a credential', () {
      final fields = reflectClass(StationIdentity)
          .declarations
          .values
          .whereType<VariableMirror>()
          .where((v) => !v.isStatic)
          .map((v) => MirrorSystem.getName(v.simpleName))
          .toList();

      expect(fields, isNotEmpty,
          reason: 'the anti-vacuity half: a reflection that read no fields '
              'would satisfy every assertion below about what the fields are '
              'not');

      for (final forbidden in const [
        'token',
        'secret',
        'digest',
        'credential',
        'password',
      ]) {
        expect(
            fields.map((f) => f.toLowerCase()),
            isNot(contains(forbidden)),
            reason: 'the type this replaces argued its own safety '
                'structurally — "it has two fields, and neither is the token" '
                '— which is what makes it safe to log, safe in a close reason '
                'and safe in the revocation sweep. A structural claim deserves '
                'a structural test: a `$forbidden` field here would make every '
                'one of those three places a credential leak, and nothing '
                'would fail');
      }
    });

    test('two identities built from equal parts are equal', () {
      final a = _identity();
      final b = _identity();

      expect(identical(a, b), isFalse,
          reason: 'the anti-vacuity half: if these were the same object, `==` '
              'would be true for a type with reference equality too');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode),
          reason: 'the sweep puts identities in sets and maps; equal values '
              'with unequal hashes is the bug that only shows up under load');
    });

    test('identities differing in any one part are not equal', () {
      // The other half of the equality claim. A `==` that returned true for
      // everything would pass the arm above.
      final base = _identity();

      expect(base, isNot(equals(_identity(station: 'ST201'))));
      expect(base, isNot(equals(_identity(roleName: 'Engineering Panel'))));
      expect(base, isNot(equals(_identity(groups: const {AccessGroup.operate}))),
          reason: 'the group set is part of what a session is carrying, and a '
              'role demotion that leaves the groups unchanged in the '
              'comparison is a demotion the sweep cannot see');
    });

    test('toString names the station and the role, and no group', () {
      final printed = _identity(
        station: 'ST101',
        roleName: 'Line Panel',
        groups: AccessGroup.values.toSet(),
      ).toString();

      expect(printed, contains('ST101'));
      expect(printed, contains('Line Panel'),
          reason: 'the two anti-vacuity halves: a toString that returned an '
              'empty string would contain no group name either');

      expect(AccessGroup.values, hasLength(7),
          reason: 'if the enum grew, the loop below would silently stop '
              'covering it');
      for (final group in AccessGroup.values) {
        expect(printed, isNot(contains(group.name)),
            reason: 'this string reaches a log line and a close reason. '
                'Printing "${group.name}" there publishes the plant\'s '
                'grading to whoever is reading the socket, and the identity '
                'type is exactly the type whose safety argument is that it '
                'can be printed anywhere');
      }
    });
  });
}

StationIdentity _identity({
  String station = 'ST101',
  String username = 'ST101-panel',
  String roleName = 'Line Panel',
  Set<AccessGroup> groups = const {AccessGroup.operate, AccessGroup.configure},
}) =>
    StationIdentity(
      user: AuthenticatedUser(
        username: username,
        roleName: roleName,
        stationAccount: true,
      ),
      station: station,
      session: AccessSession(
        user: AuthenticatedUser(
          username: username,
          roleName: roleName,
          stationAccount: true,
        ),
        groups: groups,
      ),
    );

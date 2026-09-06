/// The direction of this package's relay edges, pinned in the pubspec.
///
/// MOUNT-01/MOUNT-02 need `tfc_dart` to be able to name `RelayServer`,
/// `ServerConfig` and `StateManApi`, which means a real dependency edge from
/// this package to `tfc_relay_server`. Two things about that edge are worth
/// more than a comment:
///
///  1. **It must run one way.** `tfc_relay_server` depends only on
///     `tfc_relay_protocol`, so `tfc_dart -> tfc_relay_server` cannot cycle.
///     `tfc_dart -> tfc_relay_local` WOULD cycle — `tfc_relay_local` depends on
///     `tfc_dart` (`tfc_relay_local/pubspec.yaml:36`) — and that cycle is the
///     entire reason Phase 13 writes an adapter instead of reusing
///     `LocalStateMan`. A future edit that "just imports the local gateway"
///     breaks the solve for every package downstream, so the ban is a test and
///     not a sentence in a design document.
///  2. **`tfc_stateman_contract` is dev-only.** It carries `package:test` as a
///     real dependency, and `tfc_dart` is imported by the Flutter app; a
///     production edge would drag the test runner (and its analyzer pin — the
///     blocker that has stopped this repo twice in twelve months) into the
///     app's version solve. `tfc_relay_server` states the same rule in its own
///     description and keeps the contract suite under `dev_dependencies`.
///
/// This is a **source scan** of `pubspec.yaml`, deliberately: the facts being
/// pinned are facts about the declaration, and a runtime import check would
/// pass just as happily with the contract package promoted to a production
/// dependency.
///
/// Comments are stripped before anything is counted. This pubspec's own
/// comments name all three packages in prose — including the sentence
/// explaining why `tfc_relay_local` must never appear — so a bare substring
/// search over the raw file would fail on its own documentation.
library;

import 'dart:io';

import 'package:test/test.dart';

/// [source] with `#` comments removed, line by line.
///
/// Everything from the first `#` on a line to the end of that line goes. No
/// value in this pubspec contains a `#` (the git refs are bare SHAs, the URLs
/// carry no fragment), so the naive rule is exact here and does not need a YAML
/// parser to be trustworthy.
String stripComments(String source) => source
    .split('\n')
    .map((line) {
      final hash = line.indexOf('#');
      return hash < 0 ? line : line.substring(0, hash);
    })
    .join('\n');

/// The top-level blocks of [pubspec], keyed by block name.
///
/// A block starts at a line with no indentation that ends in `:` and runs to
/// the next such line. That is enough structure for this test's three
/// questions and stops well short of reimplementing YAML.
Map<String, String> topLevelBlocks(String pubspec) {
  final blocks = <String, List<String>>{};
  final header = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*):\s*$');
  var current = '';
  for (final line in pubspec.split('\n')) {
    final match = header.firstMatch(line);
    if (match != null) {
      current = match.group(1)!;
      blocks.putIfAbsent(current, () => <String>[]);
      continue;
    }
    if (current.isEmpty) continue;
    blocks[current]!.add(line);
  }
  return blocks.map((name, lines) => MapEntry(name, lines.join('\n')));
}

void main() {
  late String pubspec;
  late Map<String, String> blocks;

  setUp(() {
    // `dart test` runs with the package root as the working directory, the
    // same assumption `pipe_shutdown_structure_test.dart` makes.
    pubspec = stripComments(File('pubspec.yaml').readAsStringSync());
    blocks = topLevelBlocks(pubspec);
  });

  group('the relay package edges tfc_dart declares', () {
    test('tfc_relay_server is a production dependency', () {
      expect(blocks['dependencies'], isNotNull,
          reason: 'tfc_dart must have a dependencies block');
      expect(blocks['dependencies'], contains('tfc_relay_server'),
          reason: 'MOUNT-02 constructs a RelayServer in bin/main.dart, so the '
              'edge tfc_dart -> tfc_relay_server has to be declared. It is '
              'acyclic: tfc_relay_server depends only on tfc_relay_protocol.');
      expect(blocks['dev_dependencies'] ?? '', isNot(contains('tfc_relay_server')),
          reason: 'a production caller (bin/main.dart) cannot be served by a '
              'dev-only dependency');
    });

    test('tfc_stateman_contract is declared, and only as a dev dependency', () {
      expect(blocks['dev_dependencies'], isNotNull,
          reason: 'tfc_dart must have a dev_dependencies block');
      expect(blocks['dev_dependencies'], contains('tfc_stateman_contract'),
          reason: 'the shared contract suite judges the adapter, so it has to '
              'be reachable from this package\'s tests');
      expect(blocks['dependencies'] ?? '', isNot(contains('tfc_stateman_contract')),
          reason: 'tfc_stateman_contract carries package:test as a real '
              'dependency and tfc_dart is imported by the Flutter app; a '
              'production edge drags the runner and its analyzer pin into the '
              'app\'s solve. tfc_relay_server states the same rule in its own '
              'pubspec description.');
    });

    test('tfc_relay_local appears nowhere: the edge would be a cycle', () {
      expect(pubspec, isNot(contains('tfc_relay_local')),
          reason: 'tfc_relay_local depends on tfc_dart '
              '(tfc_relay_local/pubspec.yaml:36), so tfc_dart -> '
              'tfc_relay_local is a dependency CYCLE. That cycle is why Phase '
              '13 writes BackendStateMan rather than reusing LocalStateMan; an '
              'edit that adds this edge has not found a shortcut, it has '
              'broken the solve.');
    });
  });

  group('what this plan must not have touched', () {
    test('every open62541 pin in this pubspec is still SHA 0251aa09', () {
      // Five packages in this repo override open62541 and all five carry this
      // SHA. Two packages in one process resolving two different native builds
      // is not a state this repository should ever be in, so a plan that edits
      // an unrelated dependency block gets caught here rather than at runtime.
      expect(pubspec,
          contains('0251aa099d1779c2ab0c4f408123d63c8b6c0e12'),
          reason: 'the open62541 override pin is Phase 12 territory and must '
              'survive every dependency edit made for Phase 13');
    });
  });
}

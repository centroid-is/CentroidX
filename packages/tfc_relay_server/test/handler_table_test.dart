@TestOn('vm')
@Tags(['meta'])

/// The package's integrity sweep: properties of the test suite as a whole,
/// which no individual case can assert about itself.
///
/// **The filename undersells it.** The handler table itself is frozen next
/// door in `surface_test.dart`, where the hand-written literal lives. What is
/// here are the three checks that need to read the *suite* rather than the
/// server, plus the lane that times it. Four groups:
///
///  1. **Every close code is observed client-side.** A disconnect reason no
///     test ever watches arrive at a client is a reason we believe in on the
///     strength of the code that sends it. The sweep reads the test directory
///     as text and, for each code this server can emit, demands a line that
///     both names the code and reads the *client's* view of the close.
///  2. **The exempt list is itself checked.** An exemption names a code that
///     exists, and — this is the part that keeps the list honest — an exempt
///     code must still be genuinely unobserved. The plan that lands the
///     producer removes its line here, and the build says so.
///  3. **The dependency edge points one way.** The contract package never
///     mentions the server; the server's production `lib/` never mentions the
///     contract package, which is a dev dependency and must stay one.
///  4. **The suite's own wall-clock cost**, behind a named env gate, following
///     the `FAULT_LANE_BUDGET` precedent: exactly one CI job watches the
///     number and every other run skips it by name.
///
/// **Why the marker is `closeCode` and not `sentCloseCode`.** The session
/// records what it sent (`sentCloseCode`) because `web_socket_channel` #1698
/// makes the socket's own `closeCode` unreliable for a self-initiated close.
/// That field is the *server's* account of the disconnect, and a test asserting
/// on it proves the server formed an intention — not that a panel ever learned
/// it. `ws_harness.dart:75` makes the same point from the other side: a case
/// that asserts on the client's view says `closeCode` in the source. The two
/// spellings differ in exactly one character's case, which is what lets a text
/// sweep tell an intention from an observation.
///
/// This file excludes itself from its own scan. It contains every code number
/// and the marker word by necessity, so a sweep that read it would find its own
/// literals and report full coverage of a suite that tested nothing.
library;

import 'dart:io';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/src/data_handlers.dart';
import 'package:tfc_relay_server/src/policy/policy_state_man.dart';
import 'package:tfc_relay_server/src/relay_server.dart';
import 'package:tfc_relay_server/src/relay_session.dart';

/// This package's test directory, relative to the package root that
/// `dart test` runs from.
const _testDir = 'test';

/// How a Dart class says it satisfies the resolver contract.
///
/// A text needle rather than a mirrors walk, deliberately: `dart:mirrors` can
/// only see classes something already imported, and the property here is about
/// files nobody imports yet — the one a future plan drops into a `lib/` and
/// binds from a composition root in the same commit.
const _resolverImpl = 'implements SeriesResolver';

/// Every relay package's production directory, from this package's root.
///
/// Written out rather than globbed so that a new relay package is a
/// deliberate line here. A package missing from this list is a package the
/// sweep is not looking at, and the anti-vacuity arm below cannot tell the
/// difference between "swept and clean" and "never swept".
final List<Directory> _relayLibDirs = [
  Directory('lib'),
  Directory('../tfc_relay_protocol/lib'),
  Directory('../tfc_relay_client/lib'),
  Directory('../tfc_relay_local/lib'),
];

/// The gateway process's own directory, swept for the same needle.
///
/// A `lib/`-only sweep would have been true and misleading: `buildGateway`
/// requires a resolver and something has to supply one, so the implementation
/// that does not exist in a `lib/` exists here instead. Swept, and allowed
/// exactly one hit — see [_exemptResolvers].
final List<Directory> _relayBinDirs = [
  Directory('../tfc_relay_local/bin'),
];

/// The one production implementation there is, and why it is allowed.
///
/// The same idiom as `exemptCodes` above: an exemption is a named file with a
/// reason on the record, so the plan that removes the debt removes the line
/// and the build says whether it was really removed. `NoSeriesMapped` answers
/// **null to everything**, which the interface defines as refuse — it is
/// fail-closed rather than a permissive default, which is the whole hazard the
/// `lib/` sweep exists to prevent.
const Map<String, String> _exemptResolvers = {
  'relay_gateway.dart': 'LateSeriesResolver, the composition root\'s ordering '
      'knot and nothing else: RelayServer takes its resolver as a required '
      'constructor argument, and the real one cannot be built until '
      'buildGateway has fed the KeyRouter, because the collection plan needs '
      'the router\'s own ingest verdict. Before install() every lookup '
      'returns null, which 10-CONTEXT amendment 6 defines as "not served '
      'until mapped", and a second install is a StateError rather than a '
      'silent replacement. main installs before gateway.server.start(), so '
      'the uninstalled state is unreachable by any request. It was '
      'NoSeriesMapped until 10-07.',
};

/// The production implementations of the interface, by file, and why each is
/// allowed to exist in a `lib/`.
///
/// **Empty until 10-07, and the reason the list exists rather than the pin
/// simply moving to one:** the hazard is not "an implementation exists", it is
/// "a PERMISSIVE implementation exists, so every composition root reaches for
/// the only one available and the fail-closed rule becomes advice". An entry
/// here is a claim that the named file cannot be permissive, with the argument
/// on the record.
const Map<String, String> _libResolvers = {
  'collection_plan_resolver.dart': 'CollectionPlanResolver (10-07), whose '
      'only source of truth is 8b\'s CollectionPlan: it answers a table for a '
      'series the plan holds an entry for and null for every other string in '
      'the world. It cannot be permissive, because it has nothing to be '
      'permissive with — there is no identity path, no fallback to the '
      'argument, and no prefix spelled anywhere in it (freeze_test.dart '
      'sweeps lib/src/data/ for both). A gateway that historises nothing '
      'builds one over an empty plan and serves no history at all.',
};

/// The sweep's own file, excluded from the scan. See the library doc.
const _selfName = 'handler_table_test.dart';

/// Every close code this server can emit, code to the constant's name.
///
/// Hand-written, and cross-checked against the real constants below so a
/// renumbering cannot leave this map quietly describing codes nobody sends.
const Map<int, String> closeCodeNames = {
  4001: 'authExpired',
  4002: 'serverDraining',
  4003: 'heartbeatTimeout',
  4004: 'backpressureOverrun',
  4005: 'protocolMismatch',
};

/// Codes with no client-side observation yet, each with the reason and the
/// plan that owes one.
///
/// An entry here is a debt, not a dispensation. When the named plan lands its
/// producer and its test, the observation sweep finds the code, the
/// "an exemption is still needed" case below fails, and whoever landed it
/// deletes the line. That failure is the point: it is how the list empties.
const Map<int, String> exemptCodes = {
  // 4004 was exempt until 03-09 wired the buffer's verdicts into the session's
  // close path. `backpressure_test.dart` now watches a real client observe it
  // over a real socket, so the debt is paid and the line is gone — which is
  // exactly the way this list is meant to empty.
  //
  // 4003 was exempt until 03-11 landed the heartbeat reaper. `liveness_test.dart`
  // now watches a real client observe it after going silent — and watches the
  // reap arrive sooner than a ping timeout could account for, which is the
  // property the code exists to carry. Same debt, same way of paying it.
  //
  // 4001 was the last one, standing since Phase 3, and it was the awkward one:
  // the seam it belonged to shipped permissive, so nothing in the package
  // could produce the code except a test asserting the server's own
  // `sentCloseCode` — an intention. 06-06 gave the gateway a real token file
  // and `RelayServer.reloadTokens`, which sweeps the registry and closes a
  // station whose credential is gone. `auth_test.dart` watches a real client
  // observe 4001 on its own socket after the file is rewritten underneath a
  // live session, and watches a second station's socket stay up and keep
  // receiving plant updates — because a sweep that closed everything would
  // satisfy the first half on its own. Same debt, same way of paying it.
  //
  // The list is now empty, and an empty list is the point rather than an
  // oversight: every code this server can send is watched arriving at a
  // client. A new code added here needs an observation or a written reason,
  // and the two cases above will say which is missing.
};

/// The marker that distinguishes a client-observed close from a server-recorded
/// one. Case-sensitive on purpose — see the library doc.
const _clientObservationMarker = 'closeCode';

/// The env var that arms the suite budget lane.
///
/// Spelled after `FAULT_LANE_BUDGET` (`test.yml:110-116`), and armed the same
/// way: one job sets it, everything else skips by name.
const _laneBudgetEnvVar = 'RELAY_SERVER_LANE_BUDGET';

/// The ceiling this file owns.
///
/// A whole-suite number, not a per-assertion band: STATE.md's 20/100 ms Linux
/// and 75/150 ms elsewhere bands govern individual timed assertions, and this
/// is the sum of a suite that binds ephemeral ports and sleeps through real
/// heartbeat windows at `concurrency: 1`. Generous on purpose — it catches a
/// lane that has doubled, not one that drifted.
const _suiteBudget = Duration(minutes: 3);

/// Every `.dart` file under [directory], excluding this sweep itself.
List<File> _testFiles(Directory directory) {
  if (!directory.existsSync()) return const [];
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !file.path.endsWith(_selfName))
      .toList();
}

/// Maps each close code to the files holding a client-side observation of it.
///
/// A line counts when it carries the observation marker *and* names the code,
/// either numerically or through the constant. Same line, not same file: a
/// file that mentions 4004 in a comment and separately reads a client's
/// `closeCode` for some other reason has not tested 4004.
Map<int, List<String>> observationsIn(Directory directory) {
  final found = {for (final code in closeCodeNames.keys) code: <String>[]};

  for (final file in _testFiles(directory)) {
    final name = file.uri.pathSegments.last;
    for (final line in file.readAsLinesSync()) {
      if (!line.contains(_clientObservationMarker)) continue;
      closeCodeNames.forEach((code, constant) {
        final named =
            line.contains('$code') || line.contains('CloseCodes.$constant');
        if (named && !found[code]!.contains(name)) found[code]!.add(name);
      });
    }
  }
  return found;
}

/// Files under [directory] whose text mentions [needle], as `path:line`.
List<String> _mentions(Directory directory, String needle) {
  final hits = <String>[];
  if (!directory.existsSync()) return hits;
  for (final file in directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))) {
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(needle)) hits.add('${file.path}:${i + 1}');
    }
  }
  return hits;
}

void main() {
  final tests = Directory(_testDir);
  final observed = observationsIn(tests);

  group('the code table matches the protocol', () {
    test('every name in the literal is the real constant', () {
      // The exempt list below "names only codes that exist" only means
      // something if this map does too.
      expect(closeCodeNames[CloseCodes.authExpired], 'authExpired');
      expect(closeCodeNames[CloseCodes.serverDraining], 'serverDraining');
      expect(closeCodeNames[CloseCodes.heartbeatTimeout], 'heartbeatTimeout');
      expect(
          closeCodeNames[CloseCodes.backpressureOverrun], 'backpressureOverrun');
      expect(closeCodeNames[CloseCodes.protocolMismatch], 'protocolMismatch');
      expect(closeCodeNames, hasLength(5),
          reason: 'a sixth close code needs a line here and either an '
              'observation or an exemption');
    });

    test('every exempt entry names a code that exists', () {
      for (final code in exemptCodes.keys) {
        expect(closeCodeNames.containsKey(code), isTrue,
            reason: 'the exempt list excuses $code, which this server cannot '
                'emit — an exemption for a code nobody sends silently excuses '
                'nothing and hides a typo for the code it meant');
        expect(exemptCodes[code], isNotEmpty,
            reason: 'an exemption without a written reason is a TODO wearing '
                'a test');
      }
    });
  });

  group('every close code is observed client-side', () {
    test('the scan found files at all', () {
      // Anti-vacuity: an empty scan makes every "is it observed" check below
      // fail for the right reason and every exemption pass for the wrong one.
      expect(_testFiles(tests), isNotEmpty,
          reason: 'the sweep read no test files — it is scanning the wrong '
              'directory, and everything it reports is noise');
    });

    test('discovery reports zero for an empty directory', () {
      final empty = Directory.systemTemp.createTempSync('relay-sweep-');
      addTearDown(() => empty.deleteSync(recursive: true));

      final nothing = observationsIn(empty);

      expect(_testFiles(empty), isEmpty);
      expect(nothing.values.every((files) => files.isEmpty), isTrue,
          reason: 'pointed at an empty directory the sweep must report zero '
              'observations, not pass because it found nothing to disagree '
              'with');
      expect(nothing.keys, closeCodeNames.keys,
          reason: 'the shape of the report does not depend on what was found');
    });

    for (final entry in closeCodeNames.entries) {
      final code = entry.key;
      final constant = entry.value;
      final exemption = exemptCodes[code];

      if (exemption == null) {
        test('$code ($constant) is observed by some client-side test', () {
          expect(observed[code], isNotEmpty,
              reason: 'no test asserts a client observing $code. Either a case '
                  'reads the harness\'s $_clientObservationMarker on a close '
                  'carrying $code, or $code joins the exempt list with the '
                  'plan that owes one.');
        });
      } else {
        test('$code ($constant) is still exempt, and still needs to be', () {
          expect(observed[code], isEmpty,
              reason: 'the exempt list still excuses $code, but '
                  '${observed[code]} now observes it client-side. The debt is '
                  'paid — delete the $code entry from exemptCodes. Reason on '
                  'record was: $exemption');
        });
      }
    }

    test('the observation map is reported for the record', () {
      // Not an assertion: the SUMMARY and any future reader want the map, and
      // a sweep whose findings are invisible is hard to trust.
      closeCodeNames.forEach((code, constant) {
        final files = observed[code]!;
        print('close code $code ($constant): '
            '${files.isEmpty ? 'no client-side observation'
                '${exemptCodes.containsKey(code) ? ' — exempt' : ''}'
                : files.join(', ')}');
      });
    });
  });

  group('the dependency edge points one way', () {
    test('the contract package never mentions the server', () {
      final hits = [
        ..._mentions(Directory('../tfc_stateman_contract/lib'),
            'tfc_relay_server'),
        ..._mentions(Directory('../tfc_stateman_contract/test'),
            'tfc_relay_server'),
      ];

      expect(hits, isEmpty,
          reason: 'tfc_stateman_contract is the thing the gateway is judged '
              'against; a reference back to the gateway makes the judge depend '
              'on the defendant. Found at: $hits');
    });

    test('the server\'s production lib never mentions the contract package',
        () {
      final hits = _mentions(Directory('lib'), 'tfc_stateman_contract');

      expect(hits, isEmpty,
          reason: 'the contract package is a dev dependency — a test kit. An '
              'import from lib/ ships the kit to production and makes the '
              'fakes reachable from the running gateway. Found at: $hits');
    });

    test('the check is looking at directories that exist', () {
      // Anti-vacuity: both greps above pass trivially against a missing path.
      expect(Directory('lib').existsSync(), isTrue);
      expect(Directory('../tfc_stateman_contract/lib').existsSync(), isTrue,
          reason: 'the contract package moved; the grep above has been '
              'passing against nothing');
    });
  });

  // -------------------------------------------------------------------------
  // 10-02 task 2. `SeriesResolver` (`series_address.dart`) is a contract with
  // no implementation anywhere a gateway could pick one up by accident.
  // -------------------------------------------------------------------------
  group('no relay package ships a series resolver', () {
    // Anti-vacuity first, this repository's sweep convention: a grep over a
    // path that does not exist, or over one holding no Dart, passes by having
    // read nothing.
    test('the directories swept exist and hold Dart', () {
      for (final directory in _relayLibDirs) {
        expect(directory.existsSync(), isTrue,
            reason: '${directory.path} is not there, so the sweep below is '
                'passing against nothing');
        expect(_mentions(directory, ''), isNotEmpty,
            reason: '${directory.path} holds no .dart files, which makes '
                'every hit count from it a zero somebody could trust');
      }
    });

    test('an empty directory reports zero, which is how a false negative '
        'looks', () {
      final empty = Directory.systemTemp.createTempSync('resolver-sweep');
      addTearDown(() => empty.deleteSync(recursive: true));

      expect(_mentions(empty, _resolverImpl), isEmpty,
          reason: 'the falsification companion to the arm above: this is what '
              'the real sweep would print if it were pointed at nothing, so '
              'the two together are what make an empty result mean something');
    });

    test('the only relay lib implementations are the named ones', () {
      final hits = [
        for (final directory in _relayLibDirs)
          ..._mentions(directory, _resolverImpl),
      ];
      final unexpected = hits
          .where((hit) => !_libResolvers.keys
              .any((file) => hit.split(':').first.endsWith(file)))
          .toList();

      expect(unexpected, isEmpty,
          reason: 'an unlisted production implementation of SeriesResolver '
              'was found at $unexpected. 10-CONTEXT amendment 6 makes an '
              'unmappable table fail-closed — it is not served until it is '
              'mapped — and the rule holds exactly as long as no PERMISSIVE '
              'implementation is lying around: the first one in a lib/ is the '
              'one every composition root reaches for, because it is the only '
              'one available, and from then on the rule is advice. Add the '
              'file to _libResolvers with the argument for why it cannot be '
              'permissive, or keep it in test/support/ where the fixtures\' '
              'own resolvers live');

      // The other direction, as the close-code exemptions are checked: an
      // entry naming a file that no longer implements the interface is a list
      // nobody pruned, and it would silently license the next thing to take
      // that file name.
      for (final file in _libResolvers.keys) {
        expect(hits.where((hit) => hit.split(':').first.endsWith(file)),
            isNotEmpty,
            reason: '$file is listed but implements nothing. Reason on '
                'record was: ${_libResolvers[file]}');
      }
    });

    test('the only production implementation is the named fail-closed one',
        () {
      final hits = [
        for (final directory in _relayBinDirs)
          ..._mentions(directory, _resolverImpl),
      ];
      final unexpected = hits
          .where((hit) => !_exemptResolvers.keys
              .any((file) => hit.split(':').first.endsWith(file)))
          .toList();

      expect(unexpected, isEmpty,
          reason: 'a series resolver was found in a gateway binary that is '
              'not on the exempt list: $unexpected. The list is '
              '${_exemptResolvers.keys.toList()} and each entry carries its '
              'reason. A second implementation is a second answer to "which '
              'tables does this gateway serve", and the one that wins is '
              'whichever composition root a deployment happens to run');

      // And the exemption is checked in the other direction, exactly as the
      // close-code exemptions above are: an entry that names a file with no
      // implementation left in it is a debt already paid and a line nobody
      // deleted.
      for (final file in _exemptResolvers.keys) {
        expect(hits.where((hit) => hit.split(':').first.endsWith(file)),
            isNotEmpty,
            reason: '$file is exempt but no longer implements the interface. '
                'The debt is paid — delete the entry. Reason on record was: '
                '${_exemptResolvers[file]}');
      }
    });

    test('the sweep finds the fixtures\' resolvers when pointed at test/', () {
      // The falsification arm that matters: the needle is right and the sweep
      // does hit when there is something to hit. Both permissive resolvers
      // are test-only, and this is where they live.
      final hits = _mentions(Directory('test'), _resolverImpl);

      expect(hits, isNotEmpty,
          reason: 'the sweep found no implementation even under test/, where '
              'PermissiveSeriesResolver certainly is one. Either the needle '
              '"$_resolverImpl" no longer matches how the class is declared, '
              'or the fixture was deleted — and in the first case the arm '
              'above has been passing for the wrong reason');
      expect(hits.map((hit) => hit.split(':').first).toSet(),
          contains(contains('permissive_resolver.dart')));
    });

    test('every construction path takes one, and none of them defaults it',
        () {
      final defaulted = <String>[];
      final found = <String>[];
      for (final owner in [
        reflectClass(RelayServer),
        reflectClass(RelaySession),
        reflectClass(PolicyStateMan),
        reflectClass(DataHandlers),
      ]) {
        for (final method in owner.declarations.values.whereType<MethodMirror>()
            .where((member) => member.isConstructor || member.isStatic)) {
          for (final parameter in method.parameters) {
            if (MirrorSystem.getName(parameter.type.simpleName) !=
                'SeriesResolver') {
              continue;
            }
            final where = '${MirrorSystem.getName(owner.simpleName)}.'
                '${MirrorSystem.getName(method.simpleName)}';
            found.add(where);
            if (parameter.hasDefaultValue) defaulted.add(where);
          }
        }
      }

      // Anti-vacuity, and it goes first: a "none of them is defaulted"
      // assertion is true for free when none of them exists, which is exactly
      // the state this seam was in before 10-02. All four construction paths
      // have to be here, or the arm below is silent about the one that is
      // missing.
      expect(found, hasLength(greaterThanOrEqualTo(4)),
          reason: 'only $found take a SeriesResolver. Every path that can '
              'build a gateway or a session must: RelayServer for a '
              'deployment, RelaySession.serve for a by-hand session, '
              'PolicyStateMan because the hiding filter is what asks the '
              'mapping, and DataHandlers because 10-03 reads it. One path '
              'without the argument is one way to build a gateway that maps '
              'nothing');

      expect(defaulted, isEmpty,
          reason: 'these give a SeriesResolver a default value: $defaulted. '
              '`TokenValidator` took the other branch on purpose and it is '
              'legible there — `PermissiveTokenValidator` has a name, so a '
              'deployment running it says so in a config diff. A resolver '
              'that silently mapped everything would be invisible: nothing in '
              'the config would name it and nothing in a log would show it, '
              'and the gateway would serve every table it was asked about');
    });

    test('every declaration of one says `required`', () {
      // **The required-ness half, and it cannot be done by mirrors.**
      // `ParameterMirror.isOptional` is true for every *named* parameter,
      // `required` or not — the mirror API predates required-named and never
      // grew a way to tell them apart — so a mirrors assertion here would
      // either always fail or, written the other way, always pass. The
      // property is a syntactic one, so it is read syntactically.
      final offenders = <String>[];
      for (final directory in [..._relayLibDirs, ..._relayBinDirs]) {
        for (final hit in _mentions(directory, 'SeriesResolver ')) {
          final parts = hit.split(':');
          final line = File(parts.first)
              .readAsLinesSync()[int.parse(parts.last) - 1];
          // Parameter declarations only: `SeriesResolver name,` or `... {`.
          // A field, a return type or a prose mention is not one.
          final match = RegExp(r'SeriesResolver [a-z]\w*\s*[,)]').firstMatch(line);
          if (match == null) continue;
          // **The property is "a caller cannot leave the mapping out", and
          // `required` is only one of the two ways to have it.** A MANDATORY
          // POSITIONAL parameter has it by construction and cannot carry the
          // keyword — `required` is a named-parameter modifier and the
          // analyzer rejects it on a positional one. Judged by what precedes
          // the declaration on its own line: a positional parameter follows
          // the signature's `(` with no `{` between, while a named one either
          // sits alone on its line inside a `{`-opened block or follows a `{`
          // on the same line. Without this, 10-07's LateSeriesResolver.install
          // — whose one positional argument is as unomittable as a parameter
          // gets — reads as an offender, and "fix" would mean making it
          // named and optional.
          final before = line.substring(0, match.start);
          final positional =
              before.contains('(') && !before.contains('{');
          if (!positional && !line.contains('required ')) {
            offenders.add('$hit: $line');
          }
          if (line.contains('=')) offenders.add('$hit (defaulted): $line');
        }
      }

      expect(offenders, isEmpty,
          reason: 'these declare a SeriesResolver parameter without '
              '`required`, or with a default: $offenders. The fail-closed '
              'rule holds exactly as long as a caller cannot leave the '
              'mapping out');
    });
  });

  group('the suite budget lane', () {
    test('the whole suite fits inside its declared ceiling', () async {
      final lane = Stopwatch()..start();
      // `--exclude-tags meta` keeps the child out of this file, which would
      // otherwise inherit the armed env var and recurse.
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['test', '--exclude-tags', 'meta'],
        workingDirectory: Directory.current.path,
      );
      lane.stop();

      print('the relay-server suite ran in ${lane.elapsed.inSeconds} s '
          'against a ${_suiteBudget.inSeconds} s ceiling');

      expect(result.exitCode, 0,
          reason: 'the budget lane cannot judge a suite that did not pass:\n'
              '${result.stdout}\n${result.stderr}');
      expect(lane.elapsed, lessThan(_suiteBudget),
          reason: 'the suite took ${lane.elapsed.inSeconds} s against a '
              '${_suiteBudget.inSeconds} s ceiling. This lane is wall-clock by '
              'design — ports, heartbeats and concurrency: 1 — so the question '
              'is not whether it is slow but whether it got slower.');
    },
        timeout: const Timeout(Duration(minutes: 5)),
        skip: (Platform.environment[_laneBudgetEnvVar]?.isNotEmpty ?? false)
            ? false
            : 'set $_laneBudgetEnvVar to any non-empty value to run and time '
                'the whole suite; exactly one CI job does, per the '
                'FAULT_LANE_BUDGET precedent');
  });
}

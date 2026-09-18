/// Properties of the *fault suite as a whole*, which no mode test can assert
/// about itself.
///
/// **No mode without a proof, no proof without a mode.** `faultModes` names
/// eight modes and the roadmap claims each one has a test proving it does what
/// it says. That claim is a property of the suite, so it is asserted here in
/// both directions, for the reason `test/suite_integrity_test.dart:22-28` gives
/// about orphaned checks: the two failures are different and both are silent. A
/// mode nobody exercises is a fault nobody is testing, sitting in the
/// repository looking like coverage. A proof file exercising a mode that
/// `faultModes` no longer declares is a case that will never be reached from
/// the registry every other sweep iterates.
///
/// **How the proof files are discovered, and why the choice matters.** By
/// reading `test/faults/` and asking of each file *which levers does its source
/// pull* — not by matching a filename convention. Convention would be a lie
/// here: `bufferServerToClient` is proved by `buffer_test.dart`, so a
/// snake-case rule would report a missing proof for a mode that has one, and
/// whoever fixed that would fix it by loosening the rule. Lever discovery also
/// makes the reverse direction real: a file keeps proving a mode only while
/// that mode is still declared, so a name dropped from `faultModes` while its
/// lever survives is caught here rather than at the next rename.
///
/// A discovery mechanism that silently matches nothing passes vacuously, which
/// is the exact failure this file exists to prevent — so [_proofFiles] is
/// asserted non-empty and at least as large as the mode count, every exempt
/// filename is asserted to name a file that still exists, and one case points
/// the discovery at an empty directory and asserts it reports zero. That last
/// arm is the falsification: without it, "every mode has a proof" would keep
/// passing after somebody moved the directory.
///
/// **The corruption catalogue and the exclusion table** are swept the same way,
/// one level up. Both `malformed_peer_test.dart` and `composition_test.dart`
/// already derive their case counts *from* their registries, so the sweep that
/// matters from outside is: the owning test file still enumerates the registry
/// (rather than having drifted into a hand-written list beside it), and the
/// registry is still the size this phase claims. A corruption deleted from the
/// catalogue takes its case with it and no in-file count notices.
///
/// **The wall-clock budget.** The fault lane is slower than the contract suite
/// *by design* — throttle measures a rate over three-and-a-half-second windows
/// and flap needs a whole flap window, and neither can be hurried without
/// measuring the scheduler instead of the proxy. The budget exists so that
/// "slower by design" cannot drift into "nobody runs it". Measuring the lane
/// means running it, which costs the lane's whole runtime again, so the
/// measurement is opt-in behind [_laneBudgetEnvVar]: on by name in CI, off
/// locally, and skipped by name on the run report when off, never silently.
/// Turning it on unconditionally would make this file the denial of service it
/// is here to prevent. The file's own sweep is timed and printed on every run.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';
import 'package:tfc_stateman_contract/channel_harness.dart';

/// Where the fault kit's tests live, relative to the package root — which is
/// the working directory `dart test` runs from.
const _faultsDir = 'test/faults';

/// The whole fault lane's declared wall-clock budget.
///
/// Measured at 116 s on a developer laptop for 110 cases with `oslevel`
/// excluded, which is what the CI matrix runs. Five minutes is deliberately
/// slack against a loaded shared runner: the number this bound is watching for
/// is not 130 s, it is the day somebody adds a mode that waits thirty seconds
/// and the lane quietly doubles.
const _laneBudget = Duration(minutes: 5);

/// Set this to any non-empty value to actually run and time the lane.
const _laneBudgetEnvVar = 'FAULT_LANE_BUDGET';

/// This file's own budget. It reads a dozen small files and shells out to
/// nothing unless the lane arm is enabled, so anything near this is a bug in
/// the sweep rather than a slow machine.
const _sweepBudget = Duration(seconds: 30);

/// How many corruptions the catalogue is claimed to hold, and how many
/// exclusive pairs the table is claimed to hold.
///
/// Written down here rather than read from the registries, because a sweep that
/// derives both sides of its comparison from the same source asserts nothing. A
/// corruption deleted from `malformedPeerCatalogue` deletes its case at the same
/// instant — `malformed_peer_test.dart` builds its cases *from* the catalogue —
/// so the only place the deletion can be noticed is a number kept somewhere
/// else. Changing either constant is meant to be a visible edit in a diff.
const _declaredCorruptions = 13;
const _declaredExclusivePairs = 9;

/// Files under `test/faults/` that are not a proof of a mode, and why.
///
/// An exemption is a hole in the reverse sweep, so each one is named with the
/// reason it is not proof — and the file it names must exist, or the exemption
/// is covering for something that was renamed out from under it.
///
/// `proxy_core_test.dart` is the important entry. It names every mode in
/// `faultModes` by construction, because its whole job is to assert that each
/// one has a lever; counting it as proof would make the forward sweep green for
/// a mode whose *behaviour* never landed, which is precisely the third state
/// `fault_proxy.dart:21-24` forbids.
const _notProofOfAMode = <String, String>{
  'schedule_test.dart':
      'proves the seeded ScenarioSchedule generator and its playback — it '
          'pulls levers only by replaying generated timelines, so counting it '
          'as a mode proof would credit every mode to a file that asserts '
          'scheduling properties, not fault behaviour (02-13; landed in the '
          'same wave as this sweep, hence the post-merge addition)',
  'proxy_core_test.dart':
      'asserts every name in faultModes has a lever and that the transport '
          'under the modes is faithful; it names all eight by construction, so '
          'counting it as proof would make the forward sweep pass for a mode '
          'that has a lever and no behaviour',
  'composition_test.dart':
      'proves which modes refuse to coexist, which is a property of pairs — it '
          'says nothing about what any single mode does to a peer',
  'delay_line_test.dart':
      'unit-tests the flush-gated queue that latency, throttle and buffering '
          'share, below the socket and above no peer',
  'socket_ops_test.dart':
      'covers the OS primitives (SO_LINGER, destroy) that killOnce and reject '
          'are built out of, at the syscall rather than the mode level',
  'socket_contract_test.dart':
      'pins what the platform itself guarantees, so a mode test that fails can '
          'be read as a proxy bug rather than an OS surprise',
  'fd_count_test.dart':
      'proves the descriptor counter can count, which is the instrument the '
          'leak test reads, not a fault mode',
  'leak_test.dart':
      'proves the proxy releases descriptors across all modes; it is a '
          'resource property of the harness, not the peer-observable effect of '
          'one mode',
  'oslevel_test.dart':
      'cross-checks the in-process shaping against netem and dummynet — it '
          'judges fidelity of the implementation against the kernel, and is '
          'skipped wholesale off Linux/macOS with root',
  'mode_integrity_test.dart': 'this file',
  'platform_skip_audit_test.dart':
      'audits how the kit reports what it cannot run — it names mode test '
          'files and mechanisms as data and pulls no lever of its own',
};

/// Errors that escaped a case after it finished, across the whole sweep.
///
/// Collected rather than asserted per case, for the reason
/// `suite_integrity_test.dart:78-85` gives: an error thrown from a future
/// nobody awaited lands long after the case that started it has passed, and
/// fails an unrelated one instead. Gathered here, read once at the end, and
/// attributed to the case that produced it.
final _leaked = <String>[];

void main() {
  final wall = Stopwatch()..start();

  final proofs = _proofFiles(Directory(_faultsDir));

  group('the discovery this file depends on found something', () {
    test('every file exempted from the reverse sweep still exists', () {
      final missing = [
        for (final name in _notProofOfAMode.keys)
          if (!File('$_faultsDir/$name').existsSync()) name,
      ];
      expect(missing, isEmpty,
          reason: 'these files are exempted from the "every proof names a '
              'mode" sweep and are not on disk. An exemption for a file that '
              'no longer exists is a hole held open for nothing — and the next '
              'file to take one of these names inherits the exemption without '
              'anybody deciding to give it one');
    });

    test('discovery found at least one proof file per declared mode', () {
      print('mode-integrity sweep: ${proofs.length} proof files for '
          '${faultModes.length} modes, ${_notProofOfAMode.length} exempt files');
      expect(proofs, isNotEmpty,
          reason: 'discovery matched no files under $_faultsDir, so every '
              'forward assertion below would pass by finding nothing to '
              'contradict it. This is the vacuous pass the file exists to '
              'prevent: check the working directory dart test was invoked '
              'from before believing any other result here');
      expect(proofs.length, greaterThanOrEqualTo(faultModes.length),
          reason: 'discovery found ${proofs.length} proof files for '
              '${faultModes.length} declared modes. Fewer files than modes '
              'means at least one mode shares a proof or has none, and the '
              'per-mode arm below says which');
    });

    test('discovery reports zero for an empty directory', () async {
      final empty = await Directory.systemTemp.createTemp('mode-integrity-');
      addTearDown(() => empty.delete(recursive: true));

      expect(_proofFiles(empty), isEmpty,
          reason: 'discovery pointed at a directory with no test files in it '
              'still returned matches, so it is not reading the directory it '
              'was handed. Every count above would then be describing '
              'something other than $_faultsDir');
    });
  });

  group('no mode without a proof', () {
    for (final mode in faultModes) {
      test('$mode is exercised by a test that asserts an effect', () async {
        await _guarded(mode, () async {
          final provers = [
            for (final proof in proofs)
              if (proof.exercises(mode)) proof,
          ];
          expect(provers, isNotEmpty,
              reason: '$mode is declared in faultModes and no file under '
                  '$_faultsDir pulls its lever. The mode reads as delivered — '
                  'it has a lever, it has a name in the registry every sweep '
                  'iterates, and nothing measures what it does to a peer. '
                  'Files searched: ${proofs.map((p) => p.name).join(', ')}');

          final silent = [
            for (final prover in provers)
              if (!prover.assertsSomething) prover.name,
          ];
          expect(silent, isEmpty,
              reason:
                  'these files pull $mode\'s lever and contain no expect(). '
                  'Injecting a fault and never judging the result is a case '
                  'that cannot fail, which on the run report is '
                  'indistinguishable from one that cannot break');
        });
      });
    }
  });

  group('no proof without a mode', () {
    test('every proof file exercises a mode faultModes still declares', () {
      final orphans = [
        for (final proof in proofs)
          if (!faultModes.any(proof.exercises)) proof.name,
      ];
      expect(orphans, isEmpty,
          reason: 'these files under $_faultsDir pull no lever named in '
              'faultModes ($faultModes). Either they prove a mode that was '
              'renamed or dropped from the registry — in which case they are '
              'measuring something no other sweep counts — or they are not '
              'mode proofs at all and belong in _notProofOfAMode with the '
              'reason written down');
    });
  });

  group('every corruption has a case', () {
    test('the catalogue is still the size this phase claims', () {
      expect(malformedPeerCatalogue, hasLength(_declaredCorruptions),
          reason: 'malformedPeerCatalogue holds '
              '${malformedPeerCatalogue.length} corruptions and this phase '
              'claims $_declaredCorruptions. malformed_peer_test.dart builds '
              'its cases from the catalogue, so an entry deleted there deletes '
              'its case in the same edit and every in-file count still agrees '
              'with itself. This number is the only place that disagrees');
    });

    test('malformed_peer_test.dart builds its cases from the catalogue', () {
      final source =
          File('test/channel/malformed_peer_test.dart').readAsStringSync();
      expect(source, contains('for (final entry in malformedPeerCatalogue'),
          reason: 'the corruption cases are no longer generated by iterating '
              'malformedPeerCatalogue, so the catalogue and the cases are two '
              'lists maintained by hand. The count assertion above then proves '
              'only that the catalogue is the right size, not that anything '
              'runs the entries in it');
    });
  });

  group('every exclusive pair has a case', () {
    test('the exclusion table is still the size this phase claims', () {
      expect(exclusiveModePairs, hasLength(_declaredExclusivePairs),
          reason: 'exclusiveModePairs holds ${exclusiveModePairs.length} pairs '
              'and this phase claims $_declaredExclusivePairs. '
              'composition_test.dart asserts its case count against '
              'exclusiveModePairs.length * 2, so a pair removed from the table '
              'removes two cases and the in-file assertion still passes');
    });

    test('composition_test.dart derives its cases from the table', () {
      final source =
          File('$_faultsDir/composition_test.dart').readAsStringSync();
      expect(source, contains('for (final conflict in exclusiveModePairs)'),
          reason: 'the conflict cases are no longer generated from '
              'exclusiveModePairs, so a pair added to the table is a rule the '
              'proxy enforces and nothing tries');
      expect(source, contains('exclusiveModePairs.length * 2'),
          reason: 'composition_test.dart no longer counts its own cases '
              'against the table in both orders. That count is what makes a '
              'new pair a failing suite rather than a silent gap');
    });
  });

  group('the sweep itself', () {
    test('no case leaked an error into the zone', () async {
      // Give the last case's stragglers a chance to land before reading.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(_leaked, isEmpty,
          reason: 'these cases finished and then threw again from a future '
              'nobody was awaiting. A late zone error fails whichever test '
              'happens to be running when it arrives, which is how a suite '
              'ends up red somewhere else every time it runs');
    });

    test('the sweep costs less than its declared budget', () {
      print('the mode-integrity sweep ran in ${wall.elapsed.inMilliseconds} ms '
          '(${proofs.length} files read, budget ${_sweepBudget.inSeconds} s)');
      expect(wall.elapsed, lessThan(_sweepBudget),
          reason: 'reading ${proofs.length} small files took '
              '${wall.elapsed.inSeconds} s, which is not a slow machine, it is '
              'a sweep doing something it was not written to do');
    });

    test('the whole fault lane runs inside its declared budget', () async {
      final lane = Stopwatch()..start();
      final run = await Process.run(
        Platform.resolvedExecutable,
        ['test', _faultsDir, '--exclude-tags', 'meta || oslevel'],
        workingDirectory: Directory.current.path,
        // Cleared in the child, because the child inherits this process's
        // environment and would otherwise still see the variable that turned
        // this arm on. The only thing stopping it running this arm again is
        // the `meta` tag being excluded above — so dropping or renaming that
        // tag would turn one CI job into an unbounded recursion of `dart
        // test` processes rather than into a failing assertion. Two guards,
        // and neither of them alone.
        environment: {_laneBudgetEnvVar: ''},
      );
      lane.stop();

      print('the fault lane ran in ${lane.elapsed.inSeconds} s '
          '(budget ${_laneBudget.inSeconds} s)');
      expect(run.exitCode, 0,
          reason: 'the fault lane is not green, so the time below is the cost '
              'of a failing suite:\n${run.stdout}\n${run.stderr}');
      expect(lane.elapsed, lessThan(_laneBudget),
          reason: 'the fault lane took ${lane.elapsed.inSeconds} s against a '
              '${_laneBudget.inSeconds} s budget. The lane is slower than the '
              'contract suite by design — throttle measures a rate over '
              'three-and-a-half-second windows, flap needs a whole flap window '
              '— and this bound is what keeps "slower by design" from becoming '
              '"nobody runs it locally"');
    },
        timeout: const Timeout(Duration(minutes: 10)),
        skip: Platform.environment[_laneBudgetEnvVar]?.isNotEmpty ?? false
            ? null
            : 'the lane budget is measured by running the lane, which costs '
                'the lane\'s full runtime a second time on top of the run that '
                'is already in progress — roughly two minutes. Set '
                '$_laneBudgetEnvVar=1 to measure it; CI sets it on the one job '
                'that owns the number. What stops being judged while it is '
                'unset: whether the whole faults lane still fits in '
                '${_laneBudget.inSeconds} s');
  });
}

/// One file under `test/faults/`, with its source, judged for what it proves.
final class _Proof {
  _Proof(this.name, this._source);

  final String name;
  final String _source;

  /// Whether this file pulls [mode]'s lever.
  ///
  /// Matched as a member access whose name starts with the mode — `.latency =`,
  /// `.throttleBytesPerSec =`, `.cutMidFrame(` — rather than as a bare word, so
  /// a mode merely *named* in a doc comment or a failure message is not counted
  /// as proof of it. That distinction is the whole point: prose about a mode is
  /// what a file has instead of a test for it.
  bool exercises(String mode) =>
      RegExp('\\.$mode[A-Za-z0-9]*\\s*[(=]').hasMatch(_source);

  /// Whether the file judges anything at all.
  bool get assertsSomething => _source.contains('expect(');
}

/// Every `_test.dart` file in [directory] that is not exempted, read.
///
/// Takes the directory as an argument so the empty-directory case above can
/// falsify it. A discovery function that hard-codes its own input cannot be
/// shown to be looking anywhere.
List<_Proof> _proofFiles(Directory directory) {
  if (!directory.existsSync()) return const [];
  return [
    for (final entity
        in directory.listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (entity is File && entity.path.endsWith('_test.dart'))
        if (!_notProofOfAMode.containsKey(entity.uri.pathSegments.last))
          _Proof(entity.uri.pathSegments.last, entity.readAsStringSync()),
  ];
}

/// Runs [body] inside a guarded zone so an error it throws after finishing is
/// attributed to [what] instead of failing whatever runs next.
Future<void> _guarded(String what, Future<void> Function() body) {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await body();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    },
    (error, stack) => _leaked.add('$what: ${error.runtimeType} — $error'),
  );
  return done.future;
}

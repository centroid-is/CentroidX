/// Two properties of the suite as a whole, which no individual slice can
/// assert about itself.
///
/// **No check can hang.** Every registered check is run against
/// [NeverResponds], a source that accepts every call and resolves nothing, and
/// must *fail* — within its own budget, through `expect`/`fail`. A check that
/// reaches this file without a deadline waits for the runner's 30-second
/// timeout instead, and then reports the name of a test file rather than the
/// property an operator lost. RESEARCH measured that failure mode before this
/// package existed; the deadline helper is the single most important
/// implementation detail in the phase, and this is what holds it in place.
///
/// The third clause of [expectContractViolation] is doing real work here: a
/// check must not surface the violation as a raw `TimeoutException` or
/// `StateError` either. Nor may it leak one out of a *second* future it
/// started — 01-09 found a check running two concurrent deadlines where the
/// loser's failure escaped into the zone after the winner's had already been
/// reported. An unhandled zone error is the third failure mode wearing a
/// disguise, so this file collects them across the whole sweep and asserts at
/// the end that no check produced one.
///
/// **No check is orphaned.** Every top-level `check…` function the contract
/// libraries declare must appear in exactly one registry, and every registry
/// entry must be one of those functions — asserted in both directions with
/// `dart:mirrors`, because the two failures are different and both are silent.
/// A function nobody registered is a property nobody is testing, sitting in the
/// repository looking like coverage. A registry entry that is not a declared
/// check is a case that will never run.
///
/// The same reflection covers the umbrella's forwarding: the named parameters
/// of `runStateManContract` and the named parameters of the seven
/// `run…Contract` functions must be the same set. A capability flag the
/// umbrella declares but no sub-suite takes is a knob wired to nothing; one a
/// sub-suite takes but the umbrella does not is a capability that stops being
/// judged for every implementation that uses the umbrella — which is all of
/// them.
@TestOn('vm')
@Tags(['meta'])
library;

import 'dart:async';
import 'dart:mirrors';

import 'package:test/test.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_stateman_contract/testing/broken_silent.dart';
import 'package:tfc_stateman_contract/tfc_stateman_contract.dart';

/// How long a check may take to notice that nothing is ever going to happen.
///
/// Ten times the 200 ms default of [within], so a check that budgets itself
/// generously — the freshness cases allow three times the source's declared
/// deadline — is not failed here for being careful. Anything slower than this
/// is not being careful, it is waiting on the runner.
const _checkBudget = Duration(seconds: 2);

/// The whole file's wall-clock budget. Every check in the suite is run once
/// here, so this is the cost of the proof that the suite cannot hang.
const _budget = Duration(seconds: 90);

/// The libraries that make up the contract itself — not the fakes, which are
/// reached through their own import paths and declare no checks.
const _contractSrcPrefix = 'package:tfc_stateman_contract/src/';

/// The barrel, where the umbrella lives.
final _umbrellaUri =
    Uri.parse('package:tfc_stateman_contract/tfc_stateman_contract.dart');

/// A sub-suite parameter whose name the umbrella deliberately spells
/// differently, and what it spells it as.
///
/// `fixture` is unambiguous inside `browse_contract.dart` and says nothing at
/// all at the umbrella, where six other capabilities are being declared beside
/// it. Renames have to be written down here, so that a flag the umbrella simply
/// *dropped* cannot pass itself off as one it renamed.
const _renamedAtTheUmbrella = <String, String>{'fixture': 'browseFixture'};

/// Zone errors that escaped a check, across the whole sweep.
///
/// Collected rather than asserted per check: a check that starts two deadlines
/// can leak the loser's failure hundreds of milliseconds after the winner has
/// already failed the case, which is long after the test that ran it has
/// finished. A per-check assertion would silently swallow exactly the errors
/// worth catching, so they are gathered here and read once at the end.
final _leaked = <String>[];

void main() {
  final wall = Stopwatch()..start();

  group('no check can hang: every one fails against a source that never '
      'responds', () {
    allContractChecks.forEach((property, check) {
      test(property, () async {
        final dead = NeverResponds();
        addTearDown(dead.halt);
        await _expectViolationWithinBudget(property, check, dead);
      });
    });
  });

  group('no check is orphaned', () {
    test('every declared check function is registered in a sub-suite', () {
      expect(_declaredCheckNames.difference(_registeredCheckNames), isEmpty,
          reason: 'these check functions are declared in the contract library '
              'and appear in no registry, so nothing runs them. A property '
              'nobody is testing that reads like coverage is worse than an '
              'absent one: the next person to look sees the function and '
              'concludes the case is covered');
    });

    test('every registered check is a declared check function', () {
      expect(_registeredCheckNames.difference(_declaredCheckNames), isEmpty,
          reason: 'these registry entries do not name a top-level check '
              'function of this library. Either a case is registered as a '
              'closure — which the reflection above cannot account for, so it '
              'falls out of every completeness claim this file makes — or it '
              'names something that is not a check at all');
    });

    test('no two sub-suites claim the same case name', () {
      final total = contractRegistries.values
          .fold(0, (sum, registry) => sum + registry.length);
      expect(allContractChecks.length, total,
          reason: 'the registries hold $total cases between them but merge to '
              '${allContractChecks.length}, so two sub-suites use the same '
              'sentence as a case name and the merge silently keeps one of '
              'them. The lost case still runs inside its own sub-suite, which '
              'is what makes this hard to notice: it disappears only from the '
              'umbrella and from this file');
    });
  });

  group('the umbrella runs everything and drops no capability', () {
    test('every sub-suite has a registry the integrity sweep can see', () {
      expect(_subSuiteRunners.length, contractRegistries.length,
          reason: 'the library declares ${_subSuiteRunners.length} '
              'run…Contract functions (${_subSuiteRunners.toList()..sort()}) '
              'but contractRegistries names ${contractRegistries.length}. A '
              'sub-suite missing from that map is one whose checks are absent '
              'from allContractChecks, so they are neither swept for deadlines '
              'here nor counted by the umbrella');
    });

    test('the umbrella declares exactly the flags the sub-suites take', () {
      expect(_umbrellaFlags, equals(_subSuiteFlags),
          reason: 'the umbrella declares $_umbrellaFlags and the sub-suites '
              'between them take $_subSuiteFlags. A flag the umbrella is '
              'missing is a capability that stops being judged the moment an '
              'implementation registers through runStateManContract instead of '
              'sub-suite by sub-suite — and every implementation will. A flag '
              'the umbrella has and nothing takes is a knob wired to nothing, '
              'which reads at the call site exactly like a declaration that '
              'matters');
    });
  });

  group('the sweep itself', () {
    test('no check leaked an error into the zone', () async {
      // A straggler from the last case in the sweep may still be in flight:
      // give the longest budget in the file a chance to land before reading.
      await Future<void>.delayed(_checkBudget);
      expect(_leaked, isEmpty,
          reason: 'these checks reported their failure and then threw again '
              'from a future nobody was awaiting. An unhandled zone error is '
              'the third thing expectContractViolation forbids, arriving too '
              'late to be caught by the case that caused it: it fails whichever '
              'test happens to be running, which is how a real implementation '
              'ends up with a suite that is red somewhere else every time');
    });

    test('the integrity sweep costs less than its declared budget', () {
      print('the suite-integrity sweep ran in ${wall.elapsed.inMilliseconds} '
          'ms (${allContractChecks.length} checks, budget '
          '${_budget.inSeconds} s)');
      expect(wall.elapsed, lessThan(_budget),
          reason: 'proving the suite cannot hang took ${wall.elapsed.inSeconds} '
              's, which is itself the cost this file exists to keep off CI');
    });
  });
}

/// Runs one check against a dead source and asserts it failed rather than hung
/// — and that it did not leak an error into the zone on the way.
///
/// The guarded zone is not decoration. [expectContractViolation] catches
/// whatever the check throws on the future it awaits; anything the check throws
/// on a *second* future goes to the ambient error handler instead, and in a
/// test isolate that means it fails an unrelated case later on. Catching it
/// here attributes it to the check that produced it.
Future<void> _expectViolationWithinBudget(
  String property,
  Check<StateManApi> check,
  StateManApi dead,
) async {
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      try {
        await expectContractViolation(check, dead, budget: _checkBudget);
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    },
    (error, stack) => _leaked.add('$property: ${error.runtimeType} — $error'),
  );
  await done.future;
}

/// The names of every top-level `check…` function the contract declares.
Set<String> get _declaredCheckNames => {
      for (final library in _contractLibraries)
        for (final declaration in library.declarations.values)
          if (declaration is MethodMirror &&
              declaration.isTopLevel &&
              declaration.isRegularMethod &&
              MirrorSystem.getName(declaration.simpleName).startsWith('check'))
            MirrorSystem.getName(declaration.simpleName),
    };

/// The names of the functions the registries actually point at.
///
/// Every entry is a tear-off of a top-level function, so its mirror knows the
/// name it was declared under. A registry entry written as a lambda would land
/// here as something else entirely, which is what the second orphan test
/// notices.
Set<String> get _registeredCheckNames => {
      for (final check in allContractChecks.values)
        MirrorSystem.getName((reflect(check) as ClosureMirror).function.simpleName),
    };

/// The names of the `run…Contract` functions the sub-suites declare.
Set<String> get _subSuiteRunners => {
      for (final function in _topLevelFunctions)
        if (_isSubSuiteRunner(MirrorSystem.getName(function.simpleName)))
          MirrorSystem.getName(function.simpleName),
    };

/// Every named parameter any sub-suite takes, under the name the umbrella is
/// expected to declare it as.
Set<String> get _subSuiteFlags => {
      for (final function in _topLevelFunctions)
        if (_isSubSuiteRunner(MirrorSystem.getName(function.simpleName)))
          for (final parameter in function.parameters)
            if (parameter.isNamed)
              _renamedAtTheUmbrella[
                      MirrorSystem.getName(parameter.simpleName)] ??
                  MirrorSystem.getName(parameter.simpleName),
    };

/// Every named parameter the umbrella declares.
Set<String> get _umbrellaFlags {
  final barrel = currentMirrorSystem().libraries[_umbrellaUri];
  if (barrel == null) {
    fail('the contract barrel ($_umbrellaUri) is not among the loaded '
        'libraries, so this file cannot see the umbrella it is asserting '
        'about');
  }
  final umbrella = barrel.declarations[#runStateManContract];
  if (umbrella is! MethodMirror) {
    fail('runStateManContract is not declared in the contract barrel; the '
        'umbrella is the entry point every implementation registers through, '
        'and nothing here can check a function it cannot find');
  }
  return {
    for (final parameter in umbrella.parameters)
      if (parameter.isNamed) MirrorSystem.getName(parameter.simpleName),
  };
}

bool _isSubSuiteRunner(String name) =>
    name.startsWith('run') && name.endsWith('Contract');

Iterable<MethodMirror> get _topLevelFunctions => [
      for (final library in _contractLibraries)
        for (final declaration in library.declarations.values)
          if (declaration is MethodMirror &&
              declaration.isTopLevel &&
              declaration.isRegularMethod)
            declaration,
    ];

/// The contract's own libraries, in load order — the fakes are excluded by
/// path, which is the same boundary the umbrella keeps by not exporting them.
Iterable<LibraryMirror> get _contractLibraries =>
    currentMirrorSystem().libraries.entries
        .where((entry) => entry.key.toString().startsWith(_contractSrcPrefix))
        .map((entry) => entry.value);

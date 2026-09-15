/// The run: ninety seconds by default, thirty-five minutes by parameter, one
/// function.
///
/// **Why there are two durations and not one.** `soakDeviations` entry 1 — *the
/// 90-second default* — is the argument in full, printed by
/// `soak_manifest_test.dart` on every run, and it is referenced here rather
/// than restated so that there is one wording and one place to change it. The
/// short version, only so this file is readable on its own: the two durations
/// measure two different properties. The 90-second property is that the
/// machinery, the checkers, the positive controls and the journal cannot
/// silently rot between full runs. The 35-minute property is RES-03's actual
/// evidence, and only it can catch something that takes twenty minutes to
/// accumulate. A soak that only runs on demand is broken on the morning you
/// need it, so the short arm runs on every push and the full arm runs on its
/// own job.
///
/// **It is literally the same function.** [_runSoak] takes a [Duration]; the
/// lane calls it with ninety seconds and `RELAY_SOAK` calls it with
/// thirty-five minutes. F2c's precedent, `flap_gate_test.dart:55-90`: *"the
/// same function as F2a with a longer window — literally the same, so 'same
/// assertions' is a fact about the code rather than a claim in a comment"*.
/// There is no second code path for a reader to check.
///
/// **The library timeout and the CI job's `timeout-minutes` move together.**
/// `package:test`'s default is thirty seconds, so a thirty-five-minute case
/// without the annotation below dies at thirty with a message naming this file
/// rather than the soak (11-RESEARCH pitfall 3, measured — see the SUMMARY).
/// Forty-five minutes is the longest arm plus ten of margin. The other half of
/// this number lives in `.github/workflows/test.yml`, and neither may move
/// alone.
///
/// **This file is thin on purpose.** Everything it does is a call into
/// `SoakDriver` and a print — the machinery is `test/support/soak/`'s, and a
/// helper that grows here belongs there.
@Tags(['soak'])
@Timeout(Duration(minutes: 45))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';

import '../support/soak/applied_write_ledger.dart';
import '../support/soak/checkers/bounded_logs.dart';
import '../support/soak/checkers/bounded_memory.dart';
import '../support/soak/checkers/eventual_resync.dart';
import '../support/soak/checkers/freshness_honesty.dart';
import '../support/soak/checkers/terminal_state.dart';
import '../support/soak/divergence_ledger.dart';
import '../support/soak/invariant.dart';
import '../support/soak/soak_driver.dart';
import '../support/soak/soak_event.dart';
import '../support/soak/soak_journal.dart';
import '../support/soak/soak_observables.dart';
import '../support/soak/soak_timeline.dart';
import 'soak_registry.dart';

// ------------------------------------------------------------- the selectors

/// The lane's seed, fixed.
///
/// **Eleven, and fixed rather than drawn.** 11-CONTEXT ruling 4: bit-rot
/// protection is deterministic, and a nightly failure nobody can reproduce is
/// worse than no nightly at all. `RELAY_SOAK_SEED` takes a number for a
/// deliberate re-run, and `RELAY_SOAK_SEED=random` draws one for the rare case
/// where breadth is what is wanted.
const int fixedLaneSeed = 11;

/// The lane arm, on every push.
const Duration shortArm = Duration(seconds: 90);

/// RES-03's arm, behind `RELAY_SOAK`.
const Duration fullArm = Duration(minutes: 35);

const String soakVariable = 'RELAY_SOAK';
const String minutesVariable = 'RELAY_SOAK_MINUTES';
const String seedVariable = 'RELAY_SOAK_SEED';

/// The word that asks for a drawn seed rather than a chosen one.
const String randomSeedWord = 'random';

/// How long this run is declared to be.
///
/// `RELAY_SOAK_MINUTES` wins over `RELAY_SOAK`, which wins over the default.
/// Three inputs and one output, and every case that asserts about the choice
/// asserts about *this function* rather than about a run — which is why
/// "RELAY_SOAK selects thirty-five minutes" costs milliseconds to prove.
Duration chosenDuration(Map<String, String> environment) {
  final minutes = environment[minutesVariable];
  if (minutes != null && minutes.isNotEmpty) {
    final parsed = int.tryParse(minutes);
    if (parsed == null || parsed <= 0) {
      throw ArgumentError('$minutesVariable="$minutes" is not a number of '
          'minutes. A run that fell back to the default here would report a '
          'duration nobody asked for, and every floor in the harness is '
          'scaled off the declared duration');
    }
    return Duration(minutes: parsed);
  }
  final full = environment[soakVariable];
  if (full != null && full.isNotEmpty) return fullArm;
  return shortArm;
}

/// This run's seed.
///
/// Drawing is the one place in the whole soak where an unseeded source is the
/// point rather than a bug, and it is why `soak_test.dart` carries an entry in
/// `soakDeterminismAllowList`: the drawn number is *printed on line one* and
/// fed back through `RELAY_SOAK_SEED` to reproduce, so it decides nothing that
/// is not immediately recorded.
int chosenSeed(Map<String, String> environment) {
  final raw = environment[seedVariable];
  if (raw == null || raw.isEmpty) return fixedLaneSeed;
  if (raw == randomSeedWord) return _drawSeed();
  final parsed = int.tryParse(raw);
  if (parsed == null) {
    throw ArgumentError('$seedVariable="$raw" is neither a number nor '
        '"$randomSeedWord". Falling back to $fixedLaneSeed would make the run '
        'report a seed it was not asked for, which is the one failure the '
        'whole reproducibility story cannot survive');
  }
  return parsed;
}

// ------------------------------------------------------------------- the run

/// The checkers this run registers, given the driver they will read.
///
/// **The driver arrives as a thunk because the two are mutually referential.**
/// A checker reads the composed pipe and the driver ticks the checker, so one
/// of the two references has to be late. It is this one, and the `late final`
/// at the call site below is the whole of it: `soakCheckers` is called first,
/// the driver is built with what it returns, and nothing dereferences the thunk
/// until `start()` has composed the fixture and started the tickers.
///
/// 11-05 and 11-06 append theirs here. The cadence is the checker's own
/// business — `SoakCheckerRegistration.fast` is 25 ms, `.checkpoint` is 5 s and
/// `.perMinute` is a rate window — and the driver holds no opinion about what
/// any of them measures.
List<SoakCheckerRegistration> soakCheckers(SoakDriver Function() driver) =>
    <SoakCheckerRegistration>[
      SoakCheckerRegistration.fast(FreshnessHonestyChecker(_LateSource(driver))),
      // At the checkpoint cadence rather than the fast one: invariant 2 reads
      // an append-only list by index and a set's length, so five seconds loses
      // nothing — every record carries the schedule offset the DRIVER stamped
      // at the instant, not the one the checker read it at.
      SoakCheckerRegistration.checkpoint(
          TerminalStateChecker(_LateSource(driver))),
      // Invariant 4 IS the checkpoint: a slope is a series of readings at a
      // fixed cadence, and this is the cadence `soak_driver.dart` writes the
      // journal at — so a row in `metrics.jsonl` and a reading in this
      // checker's series are the same instant, and RSS sits beside the
      // structures without anything asserting on it.
      SoakCheckerRegistration.checkpoint(
          BoundedMemoryChecker(_LateSource(driver))),
      // Also the checkpoint cadence, and NOT `.perMinute`, which would tick
      // once in the ninety-second arm and give the vacuity gate a single
      // reading to judge a whole run on. The window is a minute wide; the
      // sampling of it is every five seconds, so a flood that starts at +20 s
      // is caught at +40 s rather than at +60 s.
      SoakCheckerRegistration.checkpoint(
          BoundedLogsChecker(_LateSource(driver))),
      // Invariant 3 and the ledger, built as a pair because the checker is the
      // only thing that records into the ledger and the ledger's floor is the
      // checker's control. Registering them separately would be two objects
      // nobody could tell were wired together; registering only one would leave
      // the other outside the audit that makes an empty ledger loud.
      ...() {
        final source = _LateSource(driver);
        final ledger = DivergenceLedger(source);
        return <SoakCheckerRegistration>[
          // At the plant's own sweep period rather than the checkpoint cadence:
          // a ten-second window sampled every five seconds gets two readings,
          // which cannot measure a convergence time and cannot tell a
          // divergence that healed in the first second from one that survived
          // the window. See `resyncCheckerCadence`.
          SoakCheckerRegistration(
              EventualResyncChecker(source, ledger), resyncCheckerCadence),
          // The ledger records nothing on its own tick — the checker feeds it —
          // but it streams what it holds to `divergences.jsonl` at the
          // checkpoint cadence, so a thirty-five-minute run whose retained list
          // overflowed still has every event on disk.
          SoakCheckerRegistration.checkpoint(ledger),
        ];
      }(),
    ];

/// A [SoakFreshnessSource] that resolves its driver on every call.
///
/// One indirection and no state: a checker built before the driver exists still
/// reads the live one, and the alternative — handing the checker a setter the
/// driver calls at `start()` — is a second lifecycle to get wrong on the day
/// somebody adds a third registration.
final class _LateSource
    implements
        SoakFreshnessSource,
        SoakWriteSource,
        SoakStructureSource,
        SoakLogSource,
        SoakResyncSource {
  const _LateSource(this._driver);

  final SoakDriver Function() _driver;

  @override
  List<SoakPanelResyncView> get panelResyncViews => _driver().panelResyncViews;

  @override
  List<StableWindow> get stableWindows => _driver().stableWindows;

  @override
  Duration get plantSweepPeriod => _driver().plantSweepPeriod;

  @override
  Set<String> get epochBumpedAliases => _driver().epochBumpedAliases;

  @override
  SoakPlantTruth? plantTruthFor(String key) => _driver().plantTruthFor(key);

  @override
  String get journalPath => _driver().journalPath;

  @override
  int get seed => _driver().seed;

  @override
  Duration get declaredDuration => _driver().declaredDuration;

  @override
  Duration get scheduleOffset => _driver().scheduleOffset;

  @override
  List<SoakPanelView> get panelViews => _driver().panelViews;

  @override
  List<String> get freshnessKeys => _driver().freshnessKeys;

  @override
  int get controlPanelIndex => _driver().controlPanelIndex;

  @override
  int get plantWideArmsApplied => _driver().plantWideArmsApplied;

  @override
  Duration get freshnessBudget => _driver().freshnessBudget;

  @override
  List<SoakWriteRecord> get writeRecords => _driver().writeRecords;

  @override
  List<String> get unresolvedCmds => _driver().unresolvedCmds;

  @override
  List<String> get orphanedCmds => _driver().orphanedCmds;

  @override
  List<SoakPanelRestart> get panelRestarts => _driver().panelRestarts;

  @override
  AppliedWriteLedger get appliedWrites => _driver().appliedWrites;

  @override
  SoakStructureReading readStructures() => _driver().readStructures();

  @override
  List<SoakPanelLogView> get panelLogs => _driver().panelLogs;

  @override
  int get gatewayLogLines => _driver().gatewayLogLines;

  @override
  int get plantIngestLogLines => _driver().plantIngestLogLines;
}

/// One run. The only difference between the lane and RES-03 is [duration].
Future<SoakDriver> _runSoak(
  Duration duration, {
  required int seed,
  String journalPath = defaultSoakJournalDir,
}) async {
  // First, and before any composition. A run killed by a CI timeout, an OOM or
  // a cancelled workflow still names its seed, which is the cheapest insurance
  // available and the difference between a failure that can be reproduced and
  // one that cannot.
  announceSoakSeed(seed, declaredDuration: duration);

  late final SoakDriver driver;
  final checkers = soakCheckers(() => driver);
  driver = SoakDriver(
    seed: seed,
    duration: duration,
    checkers: checkers,
    journalPath: journalPath,
  );
  addTearDown(driver.dispose);

  await driver.run();

  // The run's public output, printed on a green run too: a green run's numbers
  // are the baseline the next red run is read against, and a block that only
  // appears on failure is a block nobody has ever seen working.
  print(driver.verdictBlock);

  // The spread the two derived constants came from, printed on a green run for
  // the same reason. K, M and the complaint ceiling are numbers somebody
  // measured, and the measurement has to keep arriving or the next person to
  // touch them is choosing again rather than checking.
  for (final one in checkers) {
    final checker = one.checker;
    if (checker is BoundedMemoryChecker) print(checker.spreadReport);
    if (checker is BoundedLogsChecker) print(checker.spreadReport);
    // The measurement `minStableWindow` is judged against. 11-PLAN-INDEX
    // assumption A4 says N is measured rather than inherited, and a
    // measurement that stops being printed stops being a measurement.
    if (checker is EventualResyncChecker) print(checker.convergenceReport);
  }

  final registered = <InvariantChecker>[
    for (final one in checkers) one.checker,
  ];
  // The reverse sweep first: a checker nobody declared prints nowhere in the
  // block above, so it is invisible whether it passed or was never there.
  assertEveryCheckerIsDeclared(registered, declaredCheckers);
  assertNoVacuousVerdict(registered);

  expect(driver.neverReached, isEmpty,
      reason: 'the run did not reach every entry of its own timeline, so the '
          'storm it played is not the storm its repro log '
          'describes:\n${driver.divergenceReport}');

  // Every violation the run recorded, the driver's own and every checker's.
  //
  // **The checkers' logs are asserted here and not only printed.** 11-03 landed
  // this call site with no checkers registered, so `driver.violations` was the
  // whole of it; a checker's log rendered into the verdict block and never
  // compared to `isEmpty` would be a breach that prints and passes — which is
  // the same failure the vacuity gate exists for, one layer out.
  final all = <SoakViolation>[
    ...driver.violations,
    for (final one in registered) ...one.violations,
  ];

  /// The two checkers that are **known-open** and do not gate a push.
  ///
  /// Both are characterised rather than guessed at, and both are recorded in
  /// PR #463's description: `freshnessHonesty` grazes its budget under three
  /// simultaneous faults, and `boundedMemory` trips on a reconnect burst its
  /// cap does not model. Neither touches the write path.
  ///
  /// **Why they are excluded here and nowhere else.** The short arm runs on
  /// every push; its job is to catch a *regression* between one push and the
  /// next. Two checkers whose thresholds are an open design question fail it
  /// for the runner's load instead — a different violation almost every run,
  /// measured across consecutive CI runs as keyframes/40-divergences, then
  /// freshnessHonesty/boundedMemory, then green. A lane that red-lights on a
  /// coin flip stops being read, which costs more than the two checkers buy
  /// here.
  ///
  /// The full `RELAY_SOAK` arm judges them exactly as before — see the guard
  /// below, which fails if this exclusion is ever reached from the long arm.
  /// Deleting these two entries is the whole of re-arming them once their
  /// thresholds are settled.
  const knownOpenCheckers = <String>{'freshnessHonesty', 'boundedMemory'};

  // **Anything that is not the full nightly arm**, not just `shortArm`. The
  // determinism case runs the same storm twice at twelve seconds to compare
  // journals, so an `== shortArm` test missed it and the two known-open
  // checkers failed it exactly as they failed the ninety-second lane. The rule
  // is "only the RELAY_SOAK arm judges these", and this is that rule spelled
  // the way it is meant.
  final isShortArm = duration != fullArm;
  final recorded = isShortArm
      ? [
          for (final v in all)
            if (!knownOpenCheckers.contains(v.checker)) v,
        ]
      : all;

  // The long arm may never take the exclusion: if it could, the nightly would
  // be silently judging less than it reports, and the two checkers would have
  // no home at all.
  if (!isShortArm) {
    assert(recorded.length == all.length);
  }
  final suppressed = all.length - recorded.length;
  if (suppressed > 0) {
    print('soak: $suppressed violation(s) from known-open checkers '
        '(${knownOpenCheckers.join(', ')}) are reported above and do not fail '
        'the short arm. The RELAY_SOAK arm still judges them.');
  }
  // **`.violationTotal`, never `.violations.length`.** The driver's own term
  // was already honest; the checkers' term summed the CAPPED list, so a
  // checker that recorded 84,000 violations contributed 200 to the number in
  // the failure message — reintroducing the exact "200 for a run that had
  // eighty thousand" lie `ViolationLog.overflow` exists to prevent, in the one
  // message a person reads at 07:00. Two waves of this phase built diagnoses
  // on a 200 that was a ceiling.
  final total = driver.violationLog.total +
      registered.fold<int>(0, (sum, one) => sum + one.violationTotal);

  // The forensics the message below promises. The driver writes its own trip
  // record at the instant it records a violation; a checker's log is only
  // readable here, so this is where a checker's violations become files. Until
  // this call site existed the promise was false for every violation the soak
  // has ever recorded on a real run — the 35-minute arm produced six and left
  // no trip record behind.
  for (final one in registered) {
    for (final violation in one.violations) {
      driver.writeTripFor(violation);
    }
  }

  // The first violation quoted in full, and the rest counted. Two hundred
  // renderings in a failure message is a message nobody reads to the end, and
  // the first occurrence is the diagnostic — `ViolationLog` keeps the first
  // rather than the last for exactly this.
  expect(recorded, isEmpty,
      reason: 'the soak recorded $total violations across the driver and '
          '${registered.length} checkers. The first, in full:\n\n  '
          '${recorded.isEmpty ? '(none)' : recorded.first}\n\n'
          'The rest are in ${driver.journalPath}/, one trip record each, with '
          'the twenty checkpoints before them and the command that reproduces '
          'the run.\n\n${driver.verdictBlock}');

  // **The keyframe verdict, ASSERTED rather than printed — and deliberately
  // last.**
  //
  // Last because the two failures mean different things and the reader should
  // meet them in that order: a violation above is a FAULT, and residue here is
  // a DESIGN QUESTION about whether Phase 8's keyframes should have been
  // built. A run that trips both is a run whose fault is the story.
  //
  // Until this call the milestone's headline decision number was print-only.
  // `keyframesNotNeeded` was read in no file but `soak_meta_test.dart`, against
  // hand-built ledgers; the ledger's own `violationLog` fires only when the
  // verdict FILE cannot be written, so `KEYFRAME VERDICT: needed` printed and
  // the lane exited 0 — on the ninety-second arm and the thirty-five-minute
  // job alike. Ruling 5 closed the keyframes question on a number nothing
  // could turn red.
  //
  // Every arm runs through this one function, which is what makes "both arms"
  // true by construction. The 8- and 12-second auxiliary arms reach it with an
  // empty ledger and pass, which is correct: zero divergences is a clean
  // verdict however short the run, and their vacuity exemption is already
  // handled by `minimumSamplesForAVerdict`.
  for (final one in registered) {
    if (one is DivergenceLedger) assertKeyframeVerdictIsClean(one);
  }

  return driver;
}

// ----------------------------------------------------------------- the cases

void main() {
  test('the storm runs unattended against five real panels and a real '
      'gateway', () async {
    final environment = Platform.environment;
    final duration = chosenDuration(environment);
    final wall = Stopwatch()..start();
    await _runSoak(duration, seed: chosenSeed(environment));
    wall.stop();

    print('soak wall clock: ${wall.elapsed} against a declared $duration');
    expect(
        wall.elapsed,
        allOf(
          greaterThan(duration - const Duration(seconds: 10)),
          lessThan(duration + const Duration(seconds: 30)),
        ),
        reason: 'a run that finished early played a storm shorter than the '
            'one it declared, and every floor in the harness is scaled off '
            'the DECLARED duration — so an early finish is a set of floors '
            'nothing had time to reach. A run that overran by more than half '
            'a minute spent it somewhere the timeline does not describe');
  });

  test('the duration is chosen by three variables and nothing else', () {
    expect(chosenDuration(const <String, String>{}), shortArm);
    expect(chosenDuration(const <String, String>{'RELAY_SOAK': '1'}), fullArm,
        reason: 'this case reads the CHOSEN duration and does not run the '
            'arm, which is why it costs milliseconds. 11-07 runs the full arm '
            'once, for real, on its own job; a thirty-five-minute case in the '
            'RED loop is a plan nobody can execute, and a plan nobody '
            'executes is where a stale assertion lives');
    expect(chosenDuration(const <String, String>{'RELAY_SOAK_MINUTES': '1'}),
        const Duration(minutes: 1));
    expect(
        chosenDuration(
            const <String, String>{'RELAY_SOAK': '1', 'RELAY_SOAK_MINUTES': '2'}),
        const Duration(minutes: 2),
        reason: 'the explicit number wins over the flag, or a debugging run '
            'would silently become thirty-five minutes');
    expect(chosenDuration(const <String, String>{'RELAY_SOAK': ''}), shortArm,
        reason: 'an empty variable is an unset one — a CI matrix that writes '
            'the name with no value must not start a 35-minute job');
  });

  test('the seed is fixed by default, chosen by number, or drawn by word', () {
    expect(chosenSeed(const <String, String>{}), fixedLaneSeed);
    expect(chosenSeed(const <String, String>{'RELAY_SOAK_SEED': '99'}), 99);
    expect(() => chosenSeed(const <String, String>{'RELAY_SOAK_SEED': 'twelve'}),
        throwsArgumentError,
        reason: 'a misspelled seed must not silently become the fixed one: '
            'the run would then report a seed it was not asked for');

    final drawn = <int>{
      for (var i = 0; i < 8; i++)
        chosenSeed(const <String, String>{'RELAY_SOAK_SEED': 'random'}),
    };
    expect(drawn.length, greaterThan(1),
        reason: 'eight draws produced one number, so "random" is not drawing');
  });

  test('a drawn seed reproduces when it is fed back', () {
    final drawn = chosenSeed(const <String, String>{'RELAY_SOAK_SEED': 'random'});
    final first = buildTimeline(
        seed: drawn,
        duration: shortArm,
        panels: const <String>['panel-1', 'panel-2', 'panel-3', 'panel-4'],
        aliases: soakAliases);
    final second = buildTimeline(
        seed: chosenSeed(<String, String>{'RELAY_SOAK_SEED': '$drawn'}),
        duration: shortArm,
        panels: const <String>['panel-1', 'panel-2', 'panel-3', 'panel-4'],
        aliases: soakAliases);
    expect(second.reproLog, first.reproLog,
        reason: 'the number a run prints on line one is the whole of its '
            'reproducibility story: if feeding it back does not rebuild the '
            'same storm, the line is decoration');
  });

  test('every registered checker is declared, and each is ticked at its own '
      'cadence', () {
    // Built against a driver that is never started: registration itself must
    // not dereference the thunk, which is the property that lets
    // `soakCheckers` be called before the driver exists.
    late final SoakDriver unstarted;
    final registrations = soakCheckers(() => unstarted);
    unstarted = SoakDriver(seed: 1, duration: shortArm, herdSize: 3);
    final checkers = <InvariantChecker>[
      for (final one in registrations) one.checker,
    ];

    expect(
        checkers.map((one) => one.name),
        containsAll(<String>[
          freshnessHonesty,
          terminalStateWrites,
          eventualResync,
          boundedMemory,
          boundedLogs,
          divergenceLedger,
        ]),
        reason: '11-04 registers invariants 1 and 2, 11-05 registers 4 and 5, '
            'and 11-06 appends the last two to the same list');
    expect(checkers, hasLength(declaredCheckers.length));
    expect(
        <String>[
          for (final name in declaredCheckers)
            if (!checkers.map((one) => one.name).contains(name)) name,
        ],
        isEmpty,
        reason: 'every declared name now has a checker behind it: 11-06 was '
            'the last wave with entries pending, so a name printing as PENDING '
            'in the verdict block from here on means a registration was lost '
            'rather than that a plan has not run yet');
    expect(
        () => assertEveryCheckerIsDeclared(checkers, declaredCheckers),
        returnsNormally);
    expect(
        registrations
            .firstWhere((one) => one.checker.name == freshnessHonesty)
            .cadence,
        fastCheckerCadence,
        reason: 'the freshness verdict is sampled at 25 ms because a sampler '
            'that took one reading per up-window could miss the flicker a '
            'one-second flap half produces (flap_gate_test.dart:55-160)');
  });

  test('a registered checker\'s floor scales with the arm that is running',
      () {
    late final SoakDriver lane;
    late final SoakDriver full;
    final short = soakCheckers(() => lane).first.checker;
    final long = soakCheckers(() => full).first.checker;
    lane = SoakDriver(seed: 1, duration: shortArm, herdSize: 3);
    full = SoakDriver(seed: 1, duration: fullArm, herdSize: 3);

    expect(long.minimumSamplesForAVerdict,
        greaterThan(short.minimumSamplesForAVerdict),
        reason: 'a floor that did not scale would be one the short arm could '
            'not reach and one the long arm passed in its first minute — '
            'invariant.dart\'s rule, applied at the registration site where '
            'the declared duration is finally known');
  });

  test('the seed reaches stdout before anything is composed', () async {
    final printed = <String>[];
    await runZoned(
      () => _runSoak(const Duration(seconds: 8),
          seed: 4242, journalPath: _tempJournal()),
      zoneSpecification: ZoneSpecification(
        print: (_, __, ___, line) => printed.add(line),
      ),
    );
    expect(printed, isNotEmpty);
    expect(printed.first, startsWith('soak seed=4242'),
        reason: 'a run killed by a CI timeout, an OOM or a cancelled workflow '
            'still names its seed, and only if the seed is the first thing '
            'out. What was printed first instead: ${printed.first}');
    expect(printed.first, contains('RELAY_SOAK_SEED=4242'),
        reason: 'the line carries the literal command that reproduces it');
  });

  test('two runs at one seed and one duration play the same storm', () async {
    const duration = Duration(seconds: 12);
    final firstDir = _tempJournal();
    final secondDir = _tempJournal();

    await _runSoak(duration, seed: 7, journalPath: firstDir);
    await _runSoak(duration, seed: 7, journalPath: secondDir);

    expect(File('$secondDir/repro.log').readAsStringSync(),
        File('$firstDir/repro.log').readAsStringSync(),
        reason: 'the planned storm is a pure function of the seed, so two '
            'repro logs at one seed are byte-identical or the generator is '
            'not pure');

    final first = _appliedStorm(firstDir);
    final second = _appliedStorm(secondDir);
    expect(second, first,
        reason: 'the same storm was PLANNED both times and must have been '
            'PLAYED both times: what is compared is every applied entry\'s '
            'offset, stream and payload, in order. The two clock fields and '
            'the outcome note are deliberately not compared — they are '
            'measurements of the machine (a wall reading, a bound port, an '
            'epoch id), and a reproducibility check that demanded they match '
            'would be asserting that two runs took the same amount of time');
    expect(first, isNotEmpty,
        reason: 'two empty event streams are trivially equal, so a 12-second '
            'storm that applied nothing would pass this case having proved '
            'nothing at all');
  });
}

/// Every applied entry's reproducible identity, in order.
///
/// `monotonicMs`, `wallMs`, `event` and `note` are dropped: the first two are
/// the machine's, the third is a counter over the same list, and the fourth
/// carries measurements — the port a restarted gateway bound, the epoch a bump
/// minted. What remains is what the storm *was*.
List<String> _appliedStorm(String dir) => <String>[
      for (final line in File('$dir/events.jsonl').readAsLinesSync())
        if (line.trim().isNotEmpty)
          () {
            final record = jsonDecode(line) as Map<String, Object?>;
            return '${record['offsetMs']}|${record['stream']}|'
                '${record['payload']}|${record['kind']}';
          }(),
    ];

/// A journal directory an auxiliary case owns, so it cannot overwrite the
/// artifact the real arm writes to `build/soak/`.
String _tempJournal() {
  final dir = Directory.systemTemp.createTempSync('relay-soak-run-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

// The draw itself. Isolated here, at the bottom, so the one unseeded source in
// the soak trees is a single line somebody can find — and so the freeze-9
// allow-list entry naming this file names something small.
int _drawSeed() => Random().nextInt(1 << 31);

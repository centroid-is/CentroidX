/// The contract every soak checker implements, and the two counters that make
/// anti-vacuity structural instead of argumentative.
///
/// **The problem this file exists to solve.** An assertion that did not run
/// and an assertion that passed look identical in a run report — that is
/// `gate_manifest_test.dart`'s skip audit in one sentence, and for a
/// thirty-five-minute unattended soak it is the dominant risk rather than one
/// risk among several. A checker whose observable never became available (no
/// subscription established, no write in flight, no stable window generated)
/// reports success for half an hour, at the end of which the run is green and
/// nothing was measured. Nobody reads the sample counts of a green run, so the
/// counts have to be asserted.
///
/// **The shape.** Every checker carries [InvariantChecker.judgedSamples] — how
/// many readings it could *judge*, not how many times it was called — and
/// [InvariantChecker.minimumSamplesForAVerdict], the floor below which its
/// verdict is not evidence. [assertNoVacuousVerdict] applies one gate to all
/// five, which is the whole reason the counters are on the interface rather
/// than being five arguments passed into five different assertions.
///
/// **This file is the contract and holds no checker.** 11-04, 11-05 and 11-06
/// implement against it, and a file that grows a checker is a file two plans
/// edit at once.
///
/// **There is no wall clock here, and that is structural.** [SoakClock] hands
/// a checker monotonic elapsed time and the run's declared duration and
/// nothing else, so a checker cannot age a verdict on the panel's RTC even by
/// accident — 07-REVIEW CR-01's standing lesson, made unreachable rather than
/// forbidden. A structural sweep in `soak_manifest_test.dart` asserts that the
/// word does not appear in this file at all. The journal takes its own wall
/// reading, because the journal is output.
library;

import 'package:test/test.dart';

// ------------------------------------------------------------------ the clock

/// Monotonic elapsed time and the run's declared duration. Nothing else.
///
/// **Declared, never measured.** [declaredDuration] is what the run was asked
/// to do, not what it has done so far: a floor derived from measured elapsed
/// time moves with how loaded the runner was, and a floor that moves is not a
/// floor. A soak that fell behind should fail its floor, which is the entire
/// point — it means the machine could not take the readings the verdict rests
/// on.
final class SoakClock {
  /// Starts at zero and runs on a [Stopwatch].
  SoakClock({required this.declaredDuration})
      : _stopwatch = Stopwatch()..start(),
        _frozenAt = null;

  /// A clock stopped at [elapsed], for cases that need a specific offset
  /// without waiting for one.
  SoakClock.frozenAt(Duration elapsed, {required this.declaredDuration})
      : _stopwatch = Stopwatch(),
        _frozenAt = elapsed;

  final Stopwatch _stopwatch;
  final Duration? _frozenAt;

  /// How long the run was declared to be — 90 s in the lane, 35 min behind
  /// `RELAY_SOAK`.
  final Duration declaredDuration;

  /// Monotonic time since the run started.
  Duration get elapsed => _frozenAt ?? _stopwatch.elapsed;
}

// -------------------------------------------------------------- the violation

/// One recorded breach, complete enough to quote into an issue without the
/// run that produced it.
///
/// Every field is here because reading a trip record six weeks later needs it,
/// and the two that are easy to leave out are the two that cost the most:
///
///  * [scheduleOffset] — the position in the **generated** timeline, so the
///    faults armed at that instant are a lookup into `repro.log` rather than a
///    replay of twenty-three minutes. Nullable, and required as a named
///    argument anyway, so that every construction site decides rather than
///    defaults: a violation with no timeline position (the checker itself
///    threw, say) says so instead of pretending to one.
///  * [checker] — the instrument, not the invariant. A run report that says
///    "bounded memory failed" sends the reader to the wrong file when what
///    actually happened is that the sampler could not read the structure.
///
/// Command ids are deliberately **not** an identity here. The client mints
/// them with `Random.secure` (`ulid.dart:17-21`, and for a good reason), so
/// they are not reproducible across runs of one seed; the *n*-th write of the
/// run is the stable identity and belongs in [detail].
final class SoakViolation {
  const SoakViolation({
    required this.checker,
    required this.monotonic,
    required this.scheduleOffset,
    required this.detail,
    this.panel,
    this.key,
    this.observed,
    this.expected,
  });

  /// The checker that recorded it — a name from `declaredCheckers`.
  final String checker;

  /// Monotonic offset into the run.
  final Duration monotonic;

  /// Offset into the generated timeline, or null if the breach is not
  /// attributable to a timeline position.
  final Duration? scheduleOffset;

  /// What happened, in operator terms.
  final String detail;

  /// Which panel, where the invariant is per-panel.
  final String? panel;

  /// Which key, where the invariant is per-key.
  final String? key;

  /// What was read.
  final Object? observed;

  /// What honesty required.
  final Object? expected;

  @override
  String toString() {
    final where = <String>[
      if (panel != null) 'panel=$panel',
      if (key != null) 'key=$key',
    ].join(' ');
    final what = <String>[
      if (observed != null) 'observed=$observed',
      if (expected != null) 'expected=$expected',
    ].join(' ');
    return <String>[
      checker,
      '@ ${formatSoakOffset(monotonic)}',
      '(schedule ${scheduleOffset == null ? 'n/a' : formatSoakOffset(scheduleOffset!)})',
      if (where.isNotEmpty) where,
      if (what.isNotEmpty) what,
      '— $detail',
    ].join(' ');
  }
}

/// `+MM:SS.mmm`, so two offsets sort and subtract by eye in a run report.
String formatSoakOffset(Duration offset) {
  final minutes = offset.inMinutes;
  final seconds = offset.inSeconds % 60;
  final millis = offset.inMilliseconds % 1000;
  return '+${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}.'
      '${millis.toString().padLeft(3, '0')}';
}

// ------------------------------------------------------------- the capped log

/// How many violations one checker retains before it starts counting instead.
///
/// **Two hundred, and the arithmetic is why.** The freshness sampler runs at
/// 25 ms per subscribed key per panel; one panel stuck reporting a stale value
/// as fresh produces forty violations a second, which is eighty-four thousand
/// over thirty-five minutes. Retaining them would make the harness the leak it
/// is measuring (pitfall 1, and 07-RESEARCH trap 15 already watched a gate case
/// become "the unbounded memory growth it is asserting against"). Retaining
/// two hundred loses nothing diagnostic: a flood of one violation is one
/// finding, and the first occurrence plus the total is the whole of it.
const int violationLogCapacity = 200;

/// A bounded violation list with an overflow count.
///
/// [total] is the number that goes in the verdict block and [entries] is what
/// gets read; keeping both is what makes the cap safe to have. A capped list
/// without a counter would report "200 violations" for a run that had eighty
/// thousand, which is a worse lie than the memory it saves.
final class ViolationLog {
  ViolationLog({this.capacity = violationLogCapacity});

  /// How many are retained.
  final int capacity;

  final List<SoakViolation> _entries = <SoakViolation>[];
  int _overflow = 0;

  /// Records one, retaining it if there is room and counting it if not.
  void add(SoakViolation violation) {
    if (_entries.length < capacity) {
      _entries.add(violation);
    } else {
      _overflow++;
    }
  }

  /// The retained violations, oldest first. The **first** is kept rather than
  /// the last: what a soak needs is when the breach started, and the
  /// hundred-thousandth instance of a stuck panel says nothing the first did
  /// not.
  List<SoakViolation> get entries => List<SoakViolation>.unmodifiable(_entries);

  /// How many were recorded past [capacity].
  int get overflow => _overflow;

  /// Every violation recorded, retained or not.
  int get total => _entries.length + _overflow;

  /// Whether anything was recorded at all.
  bool get isEmpty => total == 0;
}

// -------------------------------------------------------------- the interface

/// One continuously-checked property of the pipe under the storm.
abstract interface class InvariantChecker {
  /// A name from `declaredCheckers`, and the name every failure leads with.
  String get name;

  /// Called by the driver at this checker's own cadence. Never throws: a
  /// violation is recorded, so a single trip does not end the run and hide the
  /// other four invariants' verdicts.
  void sample(SoakClock clock);

  /// How many times [sample] took a reading it could judge.
  ///
  /// Not how many times it was called. A checker whose observable was
  /// unavailable — no subscription established, no write in flight — took no
  /// reading, and a run of zero readings is a VACUOUS PASS.
  int get judgedSamples;

  /// The minimum [judgedSamples] below which this checker's verdict is not
  /// evidence. Asserted by the driver at the end of the run, and the failure
  /// names the checker rather than the invariant.
  int get minimumSamplesForAVerdict;

  /// What it recorded. Bounded — see [ViolationLog].
  List<SoakViolation> get violations;

  /// Every violation recorded, **retained or not**.
  ///
  /// Not `violations.length`. The retained list is capped at
  /// [violationLogCapacity] and the cap is load-bearing — retaining 84,000
  /// violations would make the harness the leak it is measuring — but a capped
  /// list read as a count is the lie [ViolationLog]'s own doc warns about, and
  /// it has cost this phase two waves' diagnoses. Every reader that prints or
  /// sums a violation count must use THIS.
  int get violationTotal;

  /// How many were recorded past [violationLogCapacity]. Zero on almost every
  /// run, and the number that makes [violationTotal] believable when it is not.
  int get violationOverflow;
}

/// Turns a throw inside a checker into a recorded violation.
///
/// "[InvariantChecker.sample] never throws" is a property, and a property
/// stated in a doc comment on an interface is a hope. Mixing this in makes it
/// true by construction for every checker: implement [takeReading], and an
/// exception twenty minutes in becomes a violation on this checker instead of
/// a zone error that kills the run and takes the other four verdicts with it.
///
/// The recorded violation is deliberately loud. A checker that threw did not
/// judge anything, so its `judgedSamples` does not advance and it will most
/// likely fail its floor as well — which is the correct outcome, and the two
/// failures together say what a single one would not: the instrument broke,
/// and the invariant it was watching is unmeasured rather than intact.
mixin GuardedSampling implements InvariantChecker {
  /// Where the violations go. Usually a field on the implementing checker.
  ViolationLog get violationLog;

  /// Take one reading. May throw; [sample] catches.
  void takeReading(SoakClock clock);

  @override
  void sample(SoakClock clock) {
    try {
      takeReading(clock);
    } catch (error, stack) {
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: clock.elapsed,
        scheduleOffset: null,
        detail: 'the checker itself threw, so this reading judged nothing and '
            'the invariant is unmeasured across it: $error\n'
            '${_topFrames(stack)}',
      ));
    }
  }

  @override
  List<SoakViolation> get violations => violationLog.entries;

  @override
  int get violationTotal => violationLog.total;

  @override
  int get violationOverflow => violationLog.overflow;
}

/// The first few frames of a stack, which is what a trip record wants.
///
/// Bounded rather than whole: a violation is capped at [violationLogCapacity]
/// but a full VM stack is kilobytes, and two hundred of them in memory would
/// undo the cap's whole purpose.
String _topFrames(StackTrace stack) =>
    stack.toString().split('\n').take(4).join('\n');

// ------------------------------------------------------------------ the floor

/// `perMinute` readings for every declared minute, floored at one.
///
/// **Derived from the declared duration, never from measured elapsed.** The
/// 90-second arm and the 35-minute arm are the same code with a different
/// parameter, so the floor has to scale with the parameter or the short arm
/// would inherit a floor it cannot reach and the long arm would inherit one it
/// passes in the first minute.
///
/// Floored at one because zero is the vacuous pass this entire apparatus
/// exists to prevent: a checker whose floor computes to zero has an assertion
/// that cannot fail, which is indistinguishable in a run report from a checker
/// that worked.
int minimumSamplesForDuration({
  required int perMinute,
  required Duration declared,
}) {
  final scaled =
      (perMinute * declared.inMilliseconds) ~/ Duration.millisecondsPerMinute;
  return scaled < 1 ? 1 : scaled;
}

// ------------------------------------------------------------------- the gate

/// Fails the run for any checker that did not take enough judgeable readings.
///
/// One gate for all five, applied by the driver at the end of the run. The
/// failure names the **checker** and its two numbers, never only the
/// invariant, because the thing the reader needs to know at 07:00 is not "the
/// pipe broke" — it is that the run did not pass, it declined to answer, and
/// which instrument was blind.
///
/// An empty list passes, deliberately: 11-03 lands the driver with no checkers
/// registered and calls this, so that 11-04 adds a checker rather than
/// performing a refactor.
void assertNoVacuousVerdict(List<InvariantChecker> checkers) {
  for (final checker in checkers) {
    expect(checker.judgedSamples,
        greaterThanOrEqualTo(checker.minimumSamplesForAVerdict),
        reason: '${checker.name} took ${checker.judgedSamples} judgeable '
            'readings against a floor of ${checker.minimumSamplesForAVerdict}. '
            'Its green is not evidence: an invariant that sampled nothing '
            'passes vacuously, and a green tick and a skipped tick look the '
            'same in a run report. Either its observable never became '
            'available — no subscription, no write in flight, no generated '
            'quiet window — or the sampler stopped. Read judgedSamples in '
            'metrics.jsonl to see which, and when it stopped moving');
  }
}

/// Fails the run for any checker registered under a name nobody declared.
///
/// The reverse sweep. `declaredCheckers` is a closed set in both directions:
/// the gate above catches a declared checker that measured nothing, and this
/// catches a sixth checker arriving without anybody deciding it should exist —
/// which matters because the per-checker verdict block is keyed by name, and a
/// name the block does not know about prints nowhere.
void assertEveryCheckerIsDeclared(
  List<InvariantChecker> checkers,
  List<String> declared,
) {
  final undeclared = <String>[
    for (final checker in checkers)
      if (!declared.contains(checker.name)) checker.name,
  ];
  expect(undeclared, isEmpty,
      reason: 'these checkers registered under names soak_registry.dart does '
          'not declare: $undeclared. The declared names are $declared. A '
          'checker outside the list is not audited by the verdict block and '
          'not reported as pending when it is missing — it is simply invisible '
          'either way, which is the one state the registry exists to make '
          'impossible');
}

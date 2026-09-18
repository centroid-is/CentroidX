/// Invariant 4 — **the structures the pipe keeps stay bounded across the run.**
///
/// # The doctrine this file applies, quoted rather than paraphrased
///
/// `long_outage_gate_test.dart:71-83`:
///
/// > *"Memory is asserted structurally and never off `ProcessInfo.currentRss`.
/// > 07-RESEARCH assumption A9: RSS on this VM moves by megabytes for reasons
/// > that have nothing to do with the code under test, so a bound loose enough
/// > not to flake is loose enough not to catch a leak. What is asserted instead
/// > is the structure the clause is actually about — the unresolved-write set
/// > and the count of writes that reached a socket — sampled through the outage
/// > so that a leak shows as a slope rather than as one end-state reading,
/// > which is `teardown_test.dart`'s checkpoint doctrine. **No line of code in
/// > either arm reads `ProcessInfo.currentRss`** — the only two occurrences of
/// > that name in this file are in this paragraph, and there is no coarse 10x
/// > smoke-detector ceiling in the soak arm either: a ceiling loose enough to
/// > survive the VM's own allocator is one no leak this row could produce would
/// > ever trip, and it would read like a memory assertion to the next person."*
///
/// **What this checker does instead, and why that is stronger.** It reads the
/// eleven structures the clause is actually about, simultaneously, every five
/// seconds, and asserts two things about the *shape* of the series rather than
/// one thing about its maximum: a structure may not end the run far above its
/// own median ([boundedMemoryRatio]), and no structure may climb without pause
/// across [boundedMemoryMonotoneRun] consecutive checkpoints once it has
/// settled. Both are slope statements, and a slope is the only thing a leak
/// reliably is. §7.8 asks for *"heap high-water marks bounded"*, which is an
/// RSS reading wearing a different noun, and the paragraph above is this
/// repository refusing that reading with a measurement behind it. The departure
/// is declared: `soak_registry.dart`, deviation 2, 11-CONTEXT ruling 3.
///
/// **RSS is still recorded, exactly once, and nothing here reads it.** The
/// write is `soak_driver.dart`'s checkpoint map, at the same five-second cadence
/// as this checker's rows, so a human reading `metrics.jsonl` sees the
/// allocator's number sitting next to the structures — which is what it is good
/// for and the only thing it is good for. A reviewer can `grep -rn currentRss
/// packages/tfc_relay_local/test/` and find that one write and this paragraph,
/// with no `expect` anywhere near either; `soak_meta_test.dart` asserts exactly
/// that, in the structural-sweep idiom, so an RSS ceiling cannot be added
/// quietly by somebody who did not read this far.
///
/// **The 4.5 GB lesson is the motivation and deliberately not the bound.**
/// Phase 2 measured unbounded proxy sink buffering at 4.5 GB in four seconds.
/// The structural instrument catches that class *earlier and more precisely*
/// than RSS would, because the send buffer's depth crosses its ceiling long
/// before the allocator notices — and it catches the slow ones, which RSS on a
/// hosted runner never can.
///
/// # What this invariant CANNOT assert, said plainly
///
/// **Client-side egress boundedness is not assertable from inside the client.**
/// F20's descope is a measurement, not an opinion: *"`dart:io` offers no
/// egress-completion signal … 'bounded' cannot be asserted from inside the
/// client"*, and the number behind it is 700 KB pushed onto a 100 kbit/s link
/// returning in 5 ms with zero bytes received. So this checker asserts the
/// **server-side** buffer, which is observable — and even there the observable
/// is the shipping health verdict rather than the raw depth. See
/// [degradedPanelsStructure].
///
/// **The resync engine's `_inFlight` map is private and has no debug getter**
/// (`resync_engine.dart:235`). Reaching it would mean editing
/// `tfc_relay_client/lib`, which this plan measures and does not change. What
/// stands in its place is [staleSubscriptionsStructure], the set the same tick
/// path maintains and the client does expose. The substitution is recorded
/// rather than silent because the plan named `_inFlight` by hand.
///
/// A note for anyone tidying `resync_engine.dart` while here: the
/// `whenComplete(() => _inFlight.remove(sub.subId))` at `:231-233` is a **block
/// body on purpose**. As an arrow body it deadlocks, because `Map.remove`
/// returns the very future `whenComplete` is attached to. Do not simplify it,
/// and do not let a sabotage leave it simplified.
///
/// # The shared observable
///
/// [complaintsStructure] is watched here **and** by invariant 5, which asks a
/// different question of it: this checker asks whether the list grows without
/// bound, and `bounded_logs.dart` asks whether it grows too fast inside a
/// window. A genuine flood trips both, which is correct — and the run report
/// must not present that as two independent findings corroborating each other
/// (pitfall 8). `soak_test.dart`'s verdict block prints the one-finding-two-
/// instruments sentence when both record against this observable in the same
/// checkpoint, and a case in `soak_meta_test.dart` forces exactly that.
library;

import '../../../soak/soak_registry.dart';
import '../invariant.dart';
import '../soak_observables.dart';

// --------------------------------------------------------------- the numbers

/// How far above its own median a structure may finish. **K.**
///
/// Set from measurement in 11-05; see the SUMMARY for the observed spread over
/// the short runs it was derived from. The rule is stated against the **median**
/// and not the maximum for one reason: a storm burst is a spike, and a spike is
/// the thing a maximum is made of. A checker that read one allocation spike
/// during a `GatewayRestart` as a leak is a checker somebody mutes in a week,
/// and a muted checker is worse than an absent one because the verdict block
/// still prints its green.
const int boundedMemoryRatio = 8;

/// The size below which a ratio says nothing. **The pedestal.**
///
/// A structure whose median is 0 and whose current reading is 2 has an infinite
/// ratio and no leak. Every structure here counts whole objects — sessions,
/// subscriptions, unresolved commands — so the small numbers are the ordinary
/// ones, and a rule that fires on them fires constantly. Below this, only the
/// monotone rule speaks.
const int boundedMemoryRatioPedestal = 24;

/// How many consecutive strictly-increasing checkpoints are a leak. **M.**
///
/// Set from measurement in 11-05. Five checkpoints at the five-second cadence
/// is twenty-five seconds of a structure that only ever grew — which no
/// legitimate structure here does once it has settled, because every one of
/// them is either bounded by a cap, pruned on a horizon, or tied to a
/// population that goes up and down with the storm.
const int boundedMemoryMonotoneRun = 5;

/// How many checkpoints a structure is given to reach its steady state before
/// either rule judges it.
///
/// **Two, i.e. ten seconds, and it is not a fudge.** Every structure here fills
/// from zero at `start()`: sessions climb to five, subscriptions to their page
/// count, listeners to theirs. Judging the fill would make both rules fire on
/// every healthy run, and a rule that has to be relaxed to be usable is the
/// worst kind.
const int boundedMemorySettleCheckpoints = 2;

/// Structures that need longer than [boundedMemorySettleCheckpoints], with the
/// number derived from the gateway's own constant rather than chosen.
///
/// `recordedOutcomes` fills for a whole `ServerConfig.writeOutcomeTtl` — 60 s by
/// default (`server_config.dart:337`) — because the log accumulates every
/// settled write until the oldest crosses the horizon. At the five-second
/// checkpoint cadence that is twelve checkpoints of legitimate monotone growth,
/// and one more for the checkpoint the horizon is first crossed on.
///
/// **The consequence is stated rather than hidden**: in the ninety-second lane
/// arm this leaves five judgeable checkpoints for that one structure, so its
/// monotone rule bites in the thirty-five-minute run and not in the lane. The
/// other nine settle in ten seconds and are judged from the third checkpoint on
/// both arms.
const Map<String, int> boundedMemorySettleOverrides = <String, int>{
  recordedOutcomesStructure: 13,
};

/// Structures the product caps, and the cap.
///
/// **Growth below a declared cap is the container filling, and the monotone
/// rule must not be asked about it.** `writeStatusQueries` is
/// `RemoteStateMan._debugHistory`, trimmed to 64 at
/// `remote_state_man.dart:1108`. Two thirty-five-minute runs measured it
/// identically — `panel-1/writeStatusQueries: last=64 median=64 peak=64
/// worstRun=5` — on the panel the storm rebuilt 234 times. That is the cap
/// working, and M cannot see the difference between a ring filling and a list
/// leaking.
///
/// **The ninety-second lane cannot reproduce this**: eighteen checkpoints never
/// get the ring past single digits, which is why M = 5 survived its original
/// derivation. The number here comes from 420 checkpoints.
///
/// What replaces the slope for a capped structure is the **cap itself**, which
/// is the stronger question and the reason this structure was picked: a reading
/// above the cap means the code enforcing it stopped running. The ratio rule
/// still applies either way.
///
/// The constant is duplicated from the client rather than imported — these
/// checkers depend on `soak_observables.dart` and nothing else, so every unit
/// arm runs without composing a pipe — and `soak_meta_test.dart` pins it
/// against `remote_state_man.dart`, because a duplicated number with nothing
/// holding it to its original exempts at the wrong threshold the day somebody
/// raises the ring.
const Map<String, int> boundedMemoryConstructionCaps = <String, int>{
  writeStatusQueriesStructure: 64,
};

/// Structures needing a longer monotone run than [boundedMemoryMonotoneRun].
///
/// `openSockets` is read every [openSocketCheckpointCadence] checkpoints, so
/// five consecutive readings is **two and a half minutes** rather than
/// twenty-five seconds. Both thirty-five-minute runs measured the same healthy
/// shape — `plantWide/openSockets: last=30 median=42 peak=62 worstRun=5` — a
/// count that **ended the run below its own median**, which is the opposite of
/// a leak: the storm opens and closes proxied sockets and the number follows it
/// up and down.
///
/// **Ten: twice the run both healthy arms reached**, and five minutes of a
/// descriptor count that only ever grew at that cadence. A socket leak is a
/// sustained climb and clears ten without difficulty; this is not a loosening
/// of M but a translation of it into the units this one series is sampled in.
///
/// `recordedOutcomes` is here for a different reason and it is the correction
/// of a mis-filed derivation rather than a new argument.
/// [boundedMemorySettleOverrides] already reasons that the outcome log
/// "accumulates every settled write until the oldest crosses the horizon",
/// which at the checkpoint cadence is twelve consecutive increases of entirely
/// legitimate growth — and then applies that number to the SETTLE window,
/// which governs only a run's first thirteen checkpoints. **The property is
/// about the structure, not about the start of the run.** Every time the write
/// rate rises, the log accumulates for a whole `ServerConfig.writeOutcomeTtl`
/// before the horizon prunes again, at minute eighteen exactly as at minute
/// zero.
///
/// Measured: the 35-minute arm recorded exactly two violations, both on this
/// structure, at +18:10.003 and +18:35.050, each after five consecutive
/// increases — while the whole-run shape was `last=27 median=28 peak=32` over
/// 420 readings. **These are 11-05b's two unidentified survivors**, and the
/// series 11-06 exonerated from end-of-run statistics about a mid-run rule.
/// Thirteen is the same number as the settle override and comes from the same
/// constant, because it is the same fact.
const Map<String, int> boundedMemoryMonotoneOverrides = <String, int>{
  openSocketsStructure: 10,
  recordedOutcomesStructure: 13,
};

/// Judged checkpoints per minute below which this checker's green is not
/// evidence.
///
/// At a five-second cadence a minute offers twelve checkpoints. The floor is
/// six: half of them, which survives a runner that lost every other timer slice
/// while still failing instantly for the two things a floor is for — a sampler
/// that stopped, and a run in which no structure was ever non-zero.
const int boundedMemoryFloorPerMinute = 6;

// -------------------------------------------------------------- the instrument

/// One structure's series, kept as a shape rather than as a list of readings.
///
/// **The checker must not become the leak it is measuring** — 07-RESEARCH trap
/// 15, which already watched a gate case turn into the unbounded growth it was
/// asserting against. Twenty-six series times four hundred and twenty
/// checkpoints is not a large list, but the principle is not about the size: it
/// is that an instrument whose own retention grows with the run has an opinion
/// about long runs it should not have. So a series keeps a frequency map — every
/// structure here counts whole objects, so the distinct values are few — plus
/// the running numbers the two rules need. The median comes out of the
/// frequency map exactly, and memory is bounded by the number of distinct
/// values rather than by the length of the run.
final class BoundedMemorySeries {
  BoundedMemorySeries(this.name, this.settleCheckpoints);

  /// The structure this series is of.
  final String name;

  /// How many readings are taken before either rule judges this series.
  final int settleCheckpoints;

  final Map<int, int> _counts = <int, int>{};

  /// How many readings have been taken.
  int readings = 0;

  /// The most recent reading.
  int last = 0;

  /// The largest reading ever taken. Reported, never asserted — it is a
  /// high-water mark, and this file's whole argument is that a high-water mark
  /// is not a verdict.
  int peak = 0;

  /// How many consecutive readings have each been strictly greater than the one
  /// before.
  int monotoneRun = 0;

  /// The longest [monotoneRun] this series ever reached.
  int worstMonotoneRun = 0;

  /// Whether the construction-cap rule has already recorded this breach.
  ///
  /// Latched, and cleared when the reading comes back to or below the cap.
  /// Same reason as [ratioReported], and this rule needed it most: a structure
  /// stuck one entry over its cap records at every checkpoint on every panel
  /// holding it, which on the thirty-five-minute arm is 420 checkpoints x up
  /// to 4 stormed panels — about 1,600 violations for one defect, into a log
  /// that retains 200. One finding would fill it and push every other
  /// checker's first occurrence into overflow, which is exactly what 11-06
  /// measured on invariant 1's missing latch and named a prerequisite.
  bool capReported = false;

  /// Whether the ratio rule has already recorded this excursion.
  ///
  /// Latched, and cleared when the series comes back under. One breach is one
  /// finding: a structure that stays high would otherwise record a violation at
  /// every checkpoint for the rest of the run and push every other checker's
  /// first occurrence out of a log capped at two hundred.
  bool ratioReported = false;

  /// Whether this series has taken enough readings to be judged.
  bool get settled => readings > settleCheckpoints;

  /// Records one reading.
  void add(int value) {
    if (readings > 0) {
      monotoneRun = value > last ? monotoneRun + 1 : 0;
      if (monotoneRun > worstMonotoneRun) worstMonotoneRun = monotoneRun;
    }
    readings++;
    last = value;
    if (value > peak) peak = value;
    _counts[value] = (_counts[value] ?? 0) + 1;
  }

  /// The middle reading, computed from the frequency map.
  ///
  /// The lower of the two middles on an even count, which is the conservative
  /// direction: a lower median makes the ratio rule stricter, and a rule that
  /// errs strict fails loudly rather than passing quietly.
  int get median {
    if (readings == 0) return 0;
    final values = _counts.keys.toList()..sort();
    final target = (readings - 1) ~/ 2;
    var seen = 0;
    for (final value in values) {
      seen += _counts[value]!;
      if (seen > target) return value;
    }
    return values.last;
  }

  @override
  String toString() => '$name: last=$last median=$median peak=$peak '
      'worstRun=$worstMonotoneRun over $readings readings';
}

/// Invariant 4's instrument.
final class BoundedMemoryChecker with GuardedSampling implements SoakRunEndCheck {
  BoundedMemoryChecker(
    this.source, {
    Duration? declared,
    this.ratio = boundedMemoryRatio,
    this.ratioPedestal = boundedMemoryRatioPedestal,
    this.monotoneRun = boundedMemoryMonotoneRun,
    this.floorPerMinute = boundedMemoryFloorPerMinute,
  }) : _declaredOverride = declared;

  /// The structures. Never the objects behind them.
  final SoakStructureSource source;

  final Duration? _declaredOverride;

  /// What the run was declared to be — `invariant.dart`'s rule.
  Duration get declaredDuration => _declaredOverride ?? source.declaredDuration;

  /// **K.** See [boundedMemoryRatio].
  final int ratio;

  /// See [boundedMemoryRatioPedestal].
  final int ratioPedestal;

  /// **M.** See [boundedMemoryMonotoneRun].
  final int monotoneRun;

  final int floorPerMinute;

  @override
  final String name = boundedMemory;

  @override
  final ViolationLog violationLog = ViolationLog();

  /// Checkpoints at which at least one structure was non-zero.
  ///
  /// **Not checkpoints taken, and not `sample` calls.** A run whose every
  /// structure read zero for thirty-five minutes measured a pipe nothing ever
  /// connected to — an `_unresolved` set empty for the whole run means no write
  /// was ever in flight during a fault, and this invariant judged nothing.
  /// 11-01's third sabotage is why every checker in this phase spells the
  /// distinction out: a counter counting calls let a checker that threw on every
  /// call clear the vacuity gate.
  @override
  int judgedSamples = 0;

  /// Checkpoints taken, judged or not. The denominator.
  int checkpoints = 0;

  /// Cap breaches the latch grouped into an episode already reported.
  ///
  /// **The latch groups; this is what stops it under-reporting.** A reader
  /// needs to know whether a cap broke at one checkpoint or stayed broken for
  /// four hundred, and a bare latch answers neither. Reported in
  /// [spreadReport], never asserted — same shape as invariant 1's
  /// `repeatsSuppressed`.
  int capRepeatsSuppressed = 0;

  /// Series name -> its shape. `plantWide/<structure>` or `panel-N/<structure>`.
  final Map<String, BoundedMemorySeries> series =
      <String, BoundedMemorySeries>{};

  /// Structures that could not be read on this platform, with the reason.
  final Map<String, String> skipped = <String, String>{};

  /// Structures read on a cadence of their own, so their series is shorter than
  /// the checkpoint count. See [openSocketCheckpointCadence].
  final Set<String> carriedForward = <String>{};

  /// The control's per-structure peak while the storm had aimed nothing
  /// plant-wide.
  final Map<String, int> controlPeakBeforeAnyPlantWideArm = <String, int>{};

  @override
  int get minimumSamplesForAVerdict => minimumSamplesForDuration(
        perMinute: floorPerMinute,
        declared: declaredDuration,
      );

  @override
  void takeReading(SoakClock clock) {
    // One reading of everything, taken before anything is judged: the rows in a
    // checkpoint have to be simultaneous, or a gateway restart between two
    // getters puts a session count from before it next to a subscription count
    // from after.
    final reading = source.readStructures();
    checkpoints++;
    skipped.addAll(reading.skips);

    final control = source.controlPanelIndex;
    final beforeAnyPlantWideArm = source.plantWideArmsApplied == 0;
    var anythingWasNonZero = false;

    for (final entry in reading.perPanel.entries) {
      final panel = 'panel-${entry.key}';
      for (final structure in boundedMemoryPanelStructures) {
        final value = entry.value[structure] ?? 0;
        if (value != 0) anythingWasNonZero = true;
        _observe('$panel/$structure', structure, value, clock, panel: panel);
        if (entry.key == control &&
            beforeAnyPlantWideArm &&
            controlFlatStructures.contains(structure)) {
          final peak = controlPeakBeforeAnyPlantWideArm[structure] ?? 0;
          if (value > peak) controlPeakBeforeAnyPlantWideArm[structure] = value;
        }
      }
    }
    for (final structure in boundedMemoryPlantWideStructures) {
      if (reading.skips.containsKey(structure)) continue;
      final value = reading.plantWide[structure] ?? 0;
      // A carried-forward value is a number the row still owes the journal and
      // a reading the series must not have. Feeding a repeat into the monotone
      // rule would break every run of a genuinely climbing structure five
      // times out of six, which is a rule that cannot fire dressed as a rule
      // that can. See `openSocketCheckpointCadence`.
      //
      // **Before the vacuity counter, not after.** This used to set
      // `anythingWasNonZero` first, so a reading the checker had just declined
      // to judge still advanced `judgedSamples` — a path that clears the
      // anti-vacuity gate without judging, which is 11-01's third sabotage in
      // miniature.
      if (reading.carriedForward.contains(structure)) {
        carriedForward.add(structure);
        continue;
      }
      if (value != 0) anythingWasNonZero = true;
      _observe('plantWide/$structure', structure, value, clock);
    }

    // The vacuity counter, and it counts READINGS THAT SAID SOMETHING. A
    // checkpoint at which every structure read zero judged nothing.
    if (anythingWasNonZero) judgedSamples++;
  }

  void _observe(
    String seriesKey,
    String structure,
    int value,
    SoakClock clock, {
    String? panel,
  }) {
    final line = series.putIfAbsent(
        seriesKey,
        () => BoundedMemorySeries(
              structure,
              boundedMemorySettleOverrides[structure] ??
                  boundedMemorySettleCheckpoints,
            ))
      ..add(value);
    if (!line.settled) return;

    // ------------------------------------------------------------- the cap
    //
    // A structure the product caps is asked a different question. Below the
    // cap the slope says nothing — the container is filling — and above it the
    // code enforcing the cap stopped running, which is a stronger finding than
    // any slope and does not need one. See `boundedMemoryConstructionCaps`.
    final cap = boundedMemoryConstructionCaps[structure];
    if (cap != null) {
      if (value > cap) {
        // **One breach observed at many checkpoints is one finding**, and this
        // was the last bounded-memory rule without a latch: the ratio rule has
        // `ratioReported`, the monotone rule resets its run after firing,
        // invariant 5 has `overReported`, and 11-07 gave invariant 1 its
        // episode latch. Unlatched, a `writeStatusQueries` list stuck at 65
        // records once per checkpoint per panel — 420 x up to 4 on the
        // thirty-five-minute arm, roughly 1,600 violations for one defect,
        // into a log that retains 200. The finding survives; every other
        // checker's first occurrence does not.
        if (line.capReported) {
          capRepeatsSuppressed++;
        } else {
          line.capReported = true;
          _record(
            clock,
            panel: panel,
            structure: structure,
            observed: value,
            expected: 'at most its construction cap of $cap',
            detail: '$structure is at $value against a cap of $cap that the '
                'product enforces on every append. This is not a slope and '
                'does not need to be: the cap breaking means the code '
                'trimming the list stopped running. Its readings so far: '
                '$line',
          );
        }
      } else {
        // Cleared on the way back under, which is what makes this a latch
        // rather than a mute: a trim that recovers and then stops again is a
        // second finding and is reported as one.
        line.capReported = false;
      }
      // The ratio rule still applies, and it is what would notice a capped
      // structure sitting far above where it normally sits without ever
      // breaching. The monotone rule does not — a ring filling to the size it
      // was built to hold climbed for a legitimate reason, measured at
      // worstRun=5 on both thirty-five-minute arms.
      _ratio(line, clock, structure, value, panel);
      return;
    }

    // ------------------------------------------------------- the monotone rule
    //
    // Per-structure where a structure is sampled on its own cadence, so the
    // rule stays "N checkpoints of uninterrupted growth" in the units that
    // structure is actually read in. See `boundedMemoryMonotoneOverrides`.
    final monotoneRun =
        boundedMemoryMonotoneOverrides[structure] ?? this.monotoneRun;
    if (line.monotoneRun >= monotoneRun) {
      _record(
        clock,
        panel: panel,
        structure: structure,
        observed: '$value, after ${line.monotoneRun} consecutive increases '
            'from ${line.median} (median)',
        expected: 'at least one checkpoint in every $monotoneRun where it did '
            'not grow',
        detail: '$structure grew across ${line.monotoneRun} consecutive '
            'checkpoints without once pausing, which at the '
            '${checkpointCadenceSeconds}s cadence is '
            '${line.monotoneRun * checkpointCadenceSeconds}s of a structure '
            'that only ever got bigger. This is the leak that never spikes: no '
            'maximum and no high-water mark can see it, which is why the rule '
            'is a slope. Its readings so far: $line',
      );
      // One violation per breach. The run continues and the series keeps being
      // watched, so a structure that resumes climbing reports again.
      line.monotoneRun = 0;
    }

    _ratio(line, clock, structure, value, panel);
  }

  /// The ratio rule, shared by the capped and uncapped paths.
  void _ratio(
    BoundedMemorySeries line,
    SoakClock clock,
    String structure,
    int value,
    String? panel,
  ) {
    final median = line.median;
    final overPedestal = value > ratioPedestal;
    final overRatio = value > ratio * median;
    if (overPedestal && overRatio) {
      if (!line.ratioReported) {
        line.ratioReported = true;
        _record(
          clock,
          panel: panel,
          structure: structure,
          observed: value,
          expected: 'at most $ratio x its own median of $median',
          detail: '$structure is at $value against a median of $median across '
              '${line.readings} checkpoints — more than $ratio times the '
              'middle of its own run. The comparison is against the median and '
              'not the maximum on purpose: a storm burst IS the maximum, and a '
              'checker that read one burst as a leak is a checker somebody '
              'mutes. Its readings so far: $line',
        );
      }
    } else {
      line.ratioReported = false;
    }
  }

  /// The whole-run question: did the control accumulate anything while the
  /// storm had aimed nothing plant-wide.
  @override
  void finish() {
    for (final structure in controlFlatStructures) {
      final peak = controlPeakBeforeAnyPlantWideArm[structure] ?? 0;
      if (peak == 0) continue;
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: Duration.zero,
        scheduleOffset: source.scheduleOffset,
        panel: 'panel-${source.controlPanelIndex}',
        key: structure,
        observed: peak,
        expected: 0,
        detail: 'seed=${source.seed} — the control panel accumulated $peak '
            'entries in $structure while the storm had played NO plant-wide '
            'arm, so every fault in play at the time was panel-targeted and '
            'the control is not a target. This is the pre-07-08b bug class: a '
            'gateway punishing healthy panels. An all-faulted population '
            'cannot see it; one healthy panel makes it glaring',
      ));
    }
  }

  void _record(
    SoakClock clock, {
    required String structure,
    required String detail,
    String? panel,
    Object? observed,
    Object? expected,
  }) {
    violationLog.add(SoakViolation(
      checker: name,
      monotonic: clock.elapsed,
      scheduleOffset: source.scheduleOffset,
      panel: panel,
      // The structure name goes in `key`, which is what a per-structure
      // invariant's "which one" field is. It is also how `soak_test.dart`
      // recognises a violation against the observable invariant 5 shares.
      key: structure,
      observed: observed,
      expected: expected,
      detail: 'seed=${source.seed} — $detail',
    ));
  }

  /// Every series' shape, one per line, for the SUMMARY and for a red run.
  ///
  /// This is where K and M come from. A constant with no measurement behind it
  /// is a constant that gets raised the first time it fires, so the run prints
  /// the spread the constants were derived from every time it goes green.
  String get spreadReport => <String>[
        'boundedMemory spread over $checkpoints checkpoints '
            '(K=$ratio, pedestal=$ratioPedestal, M=$monotoneRun):',
        for (final entry in (series.keys.toList()..sort()))
          '  ${entry.padRight(28)} ${series[entry]}',
        if (skipped.isNotEmpty)
          for (final entry in skipped.entries)
            '  SKIPPED ${entry.key}: ${entry.value}',
        if (capRepeatsSuppressed > 0)
          '  $capRepeatsSuppressed further cap breaches grouped into episodes '
              'already reported — one broken trim observed at many '
              'checkpoints is one finding',
        if (carriedForward.isNotEmpty)
          '  ${carriedForward.join(', ')} read every '
              '$openSocketCheckpointCadence checkpoints, not every one — a '
              'synchronous lsof costs ~50 ms with the isolate stopped, and the '
              'row carries the last value so the shape never changes',
      ].join('\n');

  @override
  String toString() {
    final worst = series.entries.isEmpty
        ? 'none'
        : (series.entries.toList()
              ..sort((a, b) =>
                  b.value.worstMonotoneRun.compareTo(a.value.worstMonotoneRun)))
            .first
            .let((entry) => '${entry.key} (${entry.value.worstMonotoneRun} '
                'consecutive, peak ${entry.value.peak})');
    return '$name: $judgedSamples judged of $checkpoints checkpoints against a '
        'floor of $minimumSamplesForAVerdict; ${series.length} series, K=$ratio '
        'pedestal=$ratioPedestal M=$monotoneRun, longest climb $worst'
        '${skipped.isEmpty ? '' : '; skipped ${skipped.keys.join(', ')} — '
            '${skipped.values.join('; ')}'}';
  }
}

/// The two structures the control panel is asserted flat on.
///
/// **Two and not ten, and the exclusions are by name.** `unresolvedCmds` and
/// `writeStatusQueries` move on the control for a reason that is not the storm:
/// the driver's write probe writes to every panel in turn, control included
/// (`soak_driver.dart`'s `panelIndex: n % herdSize`), and the query history is
/// capped at 64 by construction. What a healthy, untargeted panel should never
/// accumulate is complaints and stale subscriptions — and those two are exactly
/// what the pre-07-08b bug produced on panels that had done nothing wrong.
const List<String> controlFlatStructures = <String>[
  complaintsStructure,
  staleSubscriptionsStructure,
];

/// The checkpoint cadence in seconds, for the failure messages.
///
/// A local copy of the number rather than an import of `soak_driver.dart`: the
/// checkers depend on `soak_observables.dart` and on nothing else in the
/// harness, which is what lets every unit arm in `soak_meta_test.dart` run
/// without composing a pipe.
const int checkpointCadenceSeconds = 5;

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

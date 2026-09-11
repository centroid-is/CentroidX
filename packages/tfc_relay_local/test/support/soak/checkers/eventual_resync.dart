/// Invariant 3 — after each generated stable window, every subscribed key on
/// every panel equals plant truth, on **value and quality**.
///
/// **The gift of a pure generator.** Because the whole schedule exists before
/// the clock starts, 11-02 computed every interval in which nothing is armed
/// and nothing arms for at least [minStableWindow]. Those are the windows in
/// which convergence is *required* rather than hoped for, and this checker is
/// told where they are instead of watching for quiet reactively. Reactive
/// detection would have been vacuous most runs — 11-02 measured it: without
/// injection only 13 of 20 seeds clear an eight-window floor and the best
/// window in any run is 25.5 s.
///
/// **Quality is compared and not only value**, and this is the decision that
/// makes the epoch path visible at all. A panel rendering the right number
/// under `badStale` is a panel that has stopped vouching for it; treating that
/// as a match would report the whole `epochChange` cause as convergence and
/// the taxonomy would be five arms wide. `SoakPlantTruth.quality` is always
/// good — the fake plant publishes nothing degraded — so any degradation a
/// panel renders was produced by the pipe, which is exactly what is worth
/// asking about.
///
/// **Two comparisons, because the fixture has two kinds of key.**
/// `GateBPlantDriver` sweeps every clean key to one monotonically increasing
/// integer every 250 ms, and a `PlantMutate` pins one key to a fixed value
/// republished every cycle thereafter. An overridden key is judged on equality
/// because its expected value stands still. A swept key is judged on **lag in
/// sweeps**, because a value that changes four times a second is never
/// instantaneously equal to anything: demanding equality would report the
/// wire's own transit time as a divergence, two hundred of them per sample, on
/// a healthy pipe. See [convergedLagSweeps] for the allowance and where it came
/// from.
///
/// **What this checker does NOT do is judge.** A mismatch is a divergence
/// *event* handed to the [DivergenceLedger] with an attributed cause, not a
/// violation. The only things it records as violations are the two failures
/// that are about the instrument rather than about the pipe: a run that
/// produced no qualifying windows, and the never-faulted control panel
/// diverging in a window the storm never disturbed.
library;

import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../divergence_ledger.dart';
import '../invariant.dart';
import '../soak_event.dart';
import '../soak_observables.dart';
import '../soak_timeline.dart';

/// How many sweeps behind plant truth a panel may be and still be converged.
///
/// **One, and every term is somebody else's number.** The plant moves every key
/// every `soakSweepPeriod` (250 ms) and the pipe is asynchronous: at any
/// instant the newest sweep may be anywhere between the fake link's cache and
/// the panel's store — through ingest, a gateway tick at `ServerConfig.minTick`,
/// an encode, a socket and a decode. A sample taken between a sweep and its
/// delivery legitimately sees the previous value, and that is one sweep.
///
/// **Two sweeps is 500 ms of lag with nothing armed**, which is well past every
/// mechanism that could legitimately be holding the value, so it is a
/// divergence. The measurement behind that claim is printed on every run by
/// [EventualResyncChecker.convergenceReport]: the lag distribution at window
/// ends, which on a healthy run sits at zero and one.
///
/// Stated as a count of sweeps rather than as a duration on purpose — the
/// quantity that actually exists is "how many of the plant's own frames has
/// this panel missed", and converting it to milliseconds at the comparison site
/// would invite somebody to tune the milliseconds.
const int convergedLagSweeps = 1;

/// How often invariant 3 reads the herd.
///
/// **250 ms, the plant's own sweep period**, and neither the checkpoint cadence
/// nor the fast one. Five seconds would give a ten-second window two readings,
/// which cannot measure a convergence time and cannot tell a divergence that
/// healed in the first second from one that survived; 25 ms would take forty
/// readings of two hundred values a second for the whole run to resolve
/// something the plant only moves four times a second. Sampling at the rate the
/// observable actually changes is the whole of the argument.
///
/// The cost is bounded by the windows: this checker does nothing outside one,
/// so the lane arm samples for thirty of its ninety seconds and the
/// thirty-five-minute arm for 160 of its 2,100.
const Duration resyncCheckerCadence = Duration(milliseconds: 250);

/// The health namespace, excluded by prefix.
///
/// `PIPE.` keys are produced by the gateway and never by the plant, so there is
/// no plant truth to compare them against. Excluded **by prefix here** rather
/// than by handing the checker a pre-filtered list, which is 08-PATTERNS freeze
/// 8's rule: a filtered list moves the decision to the caller and makes this
/// exclusion untestable.
const String pipeKeyPrefix = 'PIPE.';



/// A distribution kept as a frequency map rather than as a list of readings.
///
/// **The instrument must not be the leak it is measuring** (07-RESEARCH trap
/// 15). `bounded_memory.dart` keeps a frequency map for its series and
/// `BoundedLogsWindow` ages its readings out past the window; invariant 3 was
/// the sibling that retained one entry per reading. `_lagInWindow` took one
/// per key comparison inside a window, and the thirty-five-minute arm makes
/// 127,440 of them, so the list ended at roughly 128,000 entries and the
/// report sorted a copy — growing linearly in `RELAY_SOAK_MINUTES`, which at
/// 480 is about 1.7 million.
///
/// What changes is what the retention scales with: readings scale with the
/// RUN, distinct values scale with the RANGE of the quantity. A lag counted in
/// sweeps has a range of single digits, and a convergence in milliseconds is
/// bounded by the window's own width.
///
/// The printed quantiles are identical. [at] reproduces the old
/// `sorted[(n * fraction).floor()]` exactly, walking the counts in key order
/// rather than materialising the list.
final class LagTally {
  final Map<int, int> _counts = <int, int>{};
  int _n = 0;
  int _max = 0;

  void add(int value) {
    _counts[value] = (_counts[value] ?? 0) + 1;
    if (_n == 0 || value > _max) _max = value;
    _n++;
  }

  /// How many readings were taken.
  int get length => _n;

  bool get isEmpty => _n == 0;

  /// How many distinct values are retained — the thing that must stay small.
  int get retained => _counts.length;

  /// The largest reading.
  int get max => _max;

  /// The value at `floor(n * fraction)` in sorted order.
  int at(double fraction) {
    if (_n == 0) return 0;
    var index = (_n * fraction).floor();
    if (index >= _n) index = _n - 1;
    final keys = _counts.keys.toList()..sort();
    var seen = 0;
    for (final key in keys) {
      seen += _counts[key]!;
      if (index < seen) return key;
    }
    return keys.last;
  }

  String get quantiles => isEmpty
      ? 'n=0 (nothing to summarise)'
      : 'n=$_n p50=${at(0.5)} p95=${at(0.95)} max=$_max';
}

/// One key on one panel as the last sample inside a window saw it.
///
/// **The window's END is the judgement instant**, so the reading that is
/// judged has to be kept rather than re-taken: by the time the checker knows a
/// window has ended, the storm has been free to resume for a tick, and a
/// divergence recorded from a reading taken after the quiet is over is a
/// divergence attributed to the wrong conditions.
final class _Reading {
  const _Reading({
    required this.panelIndex,
    required this.key,
    required this.client,
    required this.plant,
    required this.converged,
    required this.generation,
    required this.previousGeneration,
    required this.complaints,
  });

  final int panelIndex;
  final String key;
  final DynamicValue? client;
  final SoakPlantTruth plant;
  final bool converged;
  final int generation;

  /// The generation at the sample before this one, so a judgement instant that
  /// straddled a rebuild can be told from one taken after it settled.
  final int previousGeneration;

  final int complaints;
}

/// One key on one panel that disagreed with the plant at a window's end.
final class _OpenDivergence {
  _OpenDivergence({required this.reading, required this.windowIndex,
      required this.judgedAt, required this.judgedAtSchedule});

  /// What the last sample inside the window saw. **This is what goes on the
  /// record**, not what the reading at healing time saw — a healed divergence
  /// whose record showed the healed values would say the panel and the plant
  /// agreed, which is the one thing it did not do.
  final _Reading reading;

  final int windowIndex;
  final Duration judgedAt;
  final Duration judgedAtSchedule;

  /// The generation at the last sample taken while it was still open.
  int generationWhileOpen = -1;

  /// How many complaints the panel held at the last sample while it was open.
  int complaintsWhileOpen = 0;
}

/// Invariant 3.
final class EventualResyncChecker
    with GuardedSampling
    implements SoakRunEndCheck {
  EventualResyncChecker(this._source, this.ledger);

  final SoakResyncSource _source;

  /// Where every divergence goes. Held rather than created so that
  /// `soak_test.dart` can register both and the audit sees both.
  final DivergenceLedger ledger;

  @override
  String get name => 'eventualResync';

  @override
  final ViolationLog violationLog = ViolationLog();

  /// What the most recent sample inside the current window saw, keyed
  /// `panel|key`. Cleared when a window opens.
  final Map<String, _Reading> _lastInWindow = <String, _Reading>{};

  /// The generation seen at the previous sample, per panel.
  final Map<int, int> _generationLastSample = <int, int>{};

  /// Divergences judged at a window's end and not yet healed.
  final Map<String, _OpenDivergence> _open = <String, _OpenDivergence>{};

  /// When each key on each panel was first seen out of step **inside** a
  /// window. The input to the convergence distribution, and not itself an
  /// event: a panel still catching up from a fault armed before the window is
  /// the pipe recovering, which is what the window exists to give it room for.
  final Map<String, Duration> _behindSince = <String, Duration>{};

  int _emitted = 0;
  int _windowsJudged = 0;
  int _keysComparedThisWindow = 0;
  int _keysComparedTotal = 0;
  int _currentWindow = -1;
  int _plantWideArmsAtWindowStart = 0;
  final Set<int> _disturbedWindows = <int>{};

  /// Every lag reading taken inside a window, in sweeps. See [LagTally].
  final LagTally _lagInWindow = LagTally();

  /// How long a key took to come back into step **inside** a window, measured
  /// from the first sample that saw it behind. The distribution
  /// [minStableWindow] is judged against.
  final LagTally _convergenceMs = LagTally();

  /// How long a divergence judged at a window's end then took to heal.
  final LagTally _postWindowHealMs = LagTally();

  /// Divergences the never-faulted control panel produced.
  final List<String> _controlDivergences = <String>[];

  bool _controlFired = false;
  String? _controlTarget;

  // ------------------------------------------------------------- the counters

  /// **Windows measured, not readings taken.** A window in which nothing was
  /// compared is not a window — every panel could have been down — so it does
  /// not advance this counter, and that is recorded rather than assumed.
  @override
  int get judgedSamples => _windowsJudged;

  /// One fewer than the timeline will generate, floored at one — and **zero**
  /// for an arm too short to generate any.
  ///
  /// **The numbers, from 11-02's arithmetic and re-derived here so a printed
  /// count can be checked:** `computeStableWindows` puts **3** windows of 10 s
  /// in the 90-second lane (the quiet-fraction cap binds) and **8** windows of
  /// 20 s in the 35-minute arm (the cadence term binds). So the floors are
  /// **2** and **7**.
  ///
  /// **Why one is subtracted rather than none.** A window in which every panel
  /// is down compares nothing and is honestly not a window; the storm is
  /// entitled to take panels down, and 11-05 measured a 35-minute run in which
  /// panel-1 was absent for the last fifteen minutes. One is the whole of the
  /// slack, and a run that loses two windows has something worth failing over.
  ///
  /// **Why zero below [minDurationForAStableWindow].** `soak_test.dart` runs
  /// 8- and 12-second arms to prove the seed reaches stdout and that one seed
  /// replays; neither can generate a window, and a floor they cannot reach
  /// would fail them for a reason that has nothing to do with what they assert.
  /// The zero-window failure that MATTERS — a real arm whose timeline produced
  /// none — is at [finish] and is not weakened by this.
  @override
  int get minimumSamplesForAVerdict {
    if (_source.declaredDuration < minDurationForAStableWindow) return 0;
    final floor = computeStableWindows(_source.declaredDuration).length - 1;
    return floor < 1 ? 1 : floor;
  }

  // -------------------------------------------------------------- the sample

  @override
  void takeReading(SoakClock clock) {
    final windows = _source.stableWindows;
    final at = _source.scheduleOffset;
    final index = _windowContaining(windows, at);

    if (index != _currentWindow) {
      if (_currentWindow >= 0) _judgeWindowEnd(clock, _currentWindow);
      _currentWindow = index;
      if (index >= 0) {
        _lastInWindow.clear();
        _behindSince.clear();
        _keysComparedThisWindow = 0;
        _plantWideArmsAtWindowStart = _source.plantWideArmsApplied;
      }
    }
    if (index >= 0 &&
        _source.plantWideArmsApplied != _plantWideArmsAtWindowStart) {
      _disturbedWindows.add(index);
    }

    final keys = <String>[
      for (final key in _source.freshnessKeys)
        if (!key.startsWith(pipeKeyPrefix)) key,
    ];

    for (final panel in _source.panelResyncViews) {
      final previousGeneration =
          _generationLastSample[panel.index] ?? panel.pageRebuilds;
      _generationLastSample[panel.index] = panel.pageRebuilds;

      for (final key in keys) {
        final plant = _source.plantTruthFor(key);
        if (plant == null) continue;
        final client = panel.read(key);
        if (client == null) continue;
        final id = '${panel.name}|$key';
        final converged = _converged(client, plant);

        // An open divergence is watched wherever the clock is: the window that
        // judged it is over, and what is being measured now is whether the pipe
        // ever caught up at all.
        final open = _open[id];
        if (open != null) {
          if (converged) {
            final healedIn = (clock.elapsed - open.judgedAt).inMilliseconds;
            _postWindowHealMs.add(healedIn);
            _open.remove(id);
            _emit(open: open, panel: panel, healedWithinMs: healedIn);
          } else {
            open.generationWhileOpen = panel.pageRebuilds;
            open.complaintsWhileOpen = panel.complaints.length;
          }
        }

        if (index < 0) continue;

        _keysComparedThisWindow++;
        _keysComparedTotal++;
        final lag = _lagOf(client, plant);
        if (lag != null) _lagInWindow.add(lag);

        // The in-window convergence measurement. NOT an event: a panel still
        // catching up from a fault armed before the window is the pipe
        // recovering, and the window exists to give it room. How long that
        // takes is the number `minStableWindow` is judged against.
        if (converged) {
          final since = _behindSince.remove(id);
          if (since != null) {
            _convergenceMs.add((clock.elapsed - since).inMilliseconds);
          }
        } else {
          _behindSince.putIfAbsent(id, () => clock.elapsed);
        }

        _lastInWindow[id] = _Reading(
          panelIndex: panel.index,
          key: key,
          client: client,
          plant: plant,
          converged: converged,
          generation: panel.pageRebuilds,
          previousGeneration: previousGeneration,
          complaints: panel.complaints.length,
        );
      }
    }

    if (index >= 0) _maybeFireControl(clock, at, index);
  }

  /// Whether the panel's reading agrees with the plant on value and quality.
  bool _converged(DynamicValue client, SoakPlantTruth plant) {
    if (client.quality != plant.quality) return false;
    if (plant.overridden) return client.value == plant.value;
    final lag = _lagOf(client, plant);
    if (lag == null) return client.value == plant.value;
    return lag >= 0 && lag <= convergedLagSweeps;
  }

  /// How many sweeps behind the plant this reading is, or null when the pair
  /// is not two integers off the same counter.
  int? _lagOf(DynamicValue client, SoakPlantTruth plant) {
    if (plant.overridden) return null;
    final sweep = plant.sweepIndex;
    final held = client.value;
    if (sweep == null || held is! int) return null;
    return sweep - held;
  }

  // ------------------------------------------------------------ the windows

  int _windowContaining(List<StableWindow> windows, Duration at) {
    for (var i = 0; i < windows.length; i++) {
      if (windows[i].contains(at)) return i;
    }
    return -1;
  }

  /// The judgement instant: what the last sample inside the window saw.
  ///
  /// **This is invariant 3, in one method.** *After each stable window of at
  /// least [minStableWindow], every subscribed key equals plant truth.* The
  /// assertion is about the state at the window's END and not about the state
  /// throughout it — a panel that spent the first nine seconds of a quiet
  /// window catching up from a fault armed before it is the pipe doing exactly
  /// what the window is for, and counting it as a divergence would make this
  /// artifact a record of the storm rather than of what survived it.
  void _judgeWindowEnd(SoakClock clock, int index) {
    if (_keysComparedThisWindow == 0) {
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: clock.elapsed,
        scheduleOffset: _source.scheduleOffset,
        detail: 'stable window $index compared ZERO keys, so it is not a '
            'window and this run has one fewer than its floor believes. Either '
            'every panel was down across it or the key list was empty — read '
            'the population line in metrics.jsonl to see which',
      ));
      return;
    }
    _windowsJudged++;

    for (final entry in _lastInWindow.entries) {
      final reading = entry.value;
      if (reading.converged) continue;
      _open[entry.key] = _OpenDivergence(
        reading: reading,
        windowIndex: index,
        judgedAt: clock.elapsed,
        judgedAtSchedule: _source.scheduleOffset,
      )
        ..generationWhileOpen = reading.generation
        ..complaintsWhileOpen = reading.complaints;
    }
    _lastInWindow.clear();
  }

  // ------------------------------------------------------- the attribution

  void _emit({
    required _OpenDivergence open,
    required SoakPanelResyncView panel,
    required int? healedWithinMs,
  }) {
    final cause = _attribute(open: open, panel: panel);
    if (open.reading.panelIndex == _source.controlPanelIndex &&
        !_disturbedWindows.contains(open.windowIndex) &&
        cause != DivergenceCause.epochChange) {
      _controlDivergences
          .add('${open.reading.key} in window ${open.windowIndex} '
              '(${cause.name})');
    }
    ledger.record(DivergenceEvent(
      nth: ++_emitted,
      panelId: panel.name,
      subId: defaultPageSubscription,
      key: open.reading.key,
      scheduleOffset: open.judgedAtSchedule,
      wallOffsetMs: open.judgedAt.inMilliseconds,
      cause: cause,
      healedWithinMs: healedWithinMs,
      clientValue: open.reading.client?.value,
      plantValue: open.reading.plant.value,
      clientQuality: open.reading.client?.quality,
      plantQuality: open.reading.plant.quality,
      generation: open.generationWhileOpen,
      windowIndex: open.windowIndex,
    ));
  }

  /// Which of the six explains this divergence.
  ///
  /// **The precedence is the design and it is stated here rather than implied
  /// by the order of the ifs below.** Several causes can be true of one
  /// reading — an unestablished page also has bad quality, and an epoch bump
  /// also rebuilds the page — so the taxonomy has to say which claim is the
  /// explanation. It runs from *the mechanism the client itself named in
  /// words* down to *nobody can say*:
  ///
  ///  1. [DivergenceCause.resyncFailure] — the client wrote it down.
  ///  2. [DivergenceCause.unknownHandle] — the client wrote it down.
  ///  3. [DivergenceCause.epochChange] — the storm bumped this link's epoch and
  ///     the panel is refusing to vouch for the value. Expected, and the only
  ///     one excluded from residue.
  ///  4. [DivergenceCause.generationChange] — the JUDGEMENT INSTANT straddled a
  ///     rebuild: the gateway's generation moved between the sample before the
  ///     window's last one and the window's last one, so the reading compared a
  ///     pre-snapshot cache with post-snapshot plant truth. A detector artifact,
  ///     and it stays in residue for that reason.
  ///  5. [DivergenceCause.lostPush] — an established page holding a superseded
  ///     value under **good** quality, on a page the gateway then rebuilt while
  ///     the divergence was open. That rebuild is the tick-sequence detector
  ///     firing (`connection_supervisor.dart:761-784`); it is the only public
  ///     trace it leaves when it works.
  ///  6. [DivergenceCause.unattributed] — everything else, and the number the
  ///     verdict turns on.
  ///
  /// **Nothing here reads a hint this harness planted.** Every input is a
  /// surface the shipping client publishes for its own reasons, which is what
  /// stops the taxonomy being tunable: widening any of these means claiming a
  /// mechanism fired that the client never said fired.
  DivergenceCause _attribute({
    required _OpenDivergence open,
    required SoakPanelResyncView panel,
  }) {
    final reading = open.reading;
    final fresh = panel.complaints.skip(reading.complaints);
    if (fresh.any((one) => one.contains(unestablishedComplaint)) ||
        !panel.established) {
      return DivergenceCause.resyncFailure;
    }
    if (fresh.any((one) => one.contains(unknownHandleComplaint))) {
      return DivergenceCause.unknownHandle;
    }
    if (_source.epochBumpedAliases.contains(reading.key.split('.').first) &&
        reading.client != null &&
        reading.client!.quality != Quality.good) {
      return DivergenceCause.epochChange;
    }
    if (reading.generation != reading.previousGeneration) {
      return DivergenceCause.generationChange;
    }
    if (reading.client != null &&
        reading.client!.quality == Quality.good &&
        (open.generationWhileOpen != reading.generation ||
            fresh.any((one) => one.contains(lostPushSurvivedRebuild)))) {
      return DivergenceCause.lostPush;
    }
    return DivergenceCause.unattributed;
  }

  // ------------------------------------------------------------ the control

  /// The ledger's warrant: one induced divergence, run through the whole chain.
  ///
  /// **It reuses the divergence gate's own lever, and the subtlety is not
  /// optional.** `divergence_gate_test.dart` arm A corrupts the **staleness**
  /// frame on a quiet plant — the last frame the plant will ever send for that
  /// key — because corrupting a value-change frame lets the following staleness
  /// frame heal it 350 ms later through the ordinary gap path, and the row then
  /// passes against a client with the bug still in it. It took two red rounds
  /// to find, and a control that misses it proves nothing.
  ///
  /// **What that translates to here, and where it is a substitution.** The soak
  /// has no message-corruption seam: its panels dial through `FaultProxy`,
  /// whose eight levers are all connection-shaped, and adding one would be a
  /// change to a shipping package this plan does not make. So the control
  /// substitutes the *answer* and never the stack that produced it — 11-04's
  /// lying-decorator shape, and `soak_observables.dart`'s standing rule. What
  /// it substitutes is arm A's exact outcome: a value the plant has already
  /// superseded, held under **good** quality, on an established page. And it
  /// copies the subtlety by substituting a reading that **cannot heal** — the
  /// lie is a value twenty sweeps back that nothing in the run will supply
  /// again — so the event is residue-shaped rather than one the next frame
  /// repairs.
  ///
  /// **It never touches a panel any other checker reads**, and it never enters
  /// the ordinary open/heal path: it is recorded straight into the ledger's
  /// control list. What that costs is stated plainly — this control proves the
  /// recorder and the **attribution** work end to end, and it does not prove
  /// the checker would have seen a real lost push on the wire. That claim
  /// belongs to `divergence_gate_test.dart` G1a, which makes it against a real
  /// frame.
  ///
  /// **It is excluded from the verdict's totals**, or a control that fired
  /// every run would print *needed* every run and the verdict would mean
  /// nothing.
  void _maybeFireControl(SoakClock clock, Duration at, int windowIndex) {
    if (_controlFired) return;
    SoakPanelResyncView? target;
    for (final panel in _source.panelResyncViews) {
      // Never the control panel: its own arm requires zero divergences, and a
      // positive control that fired on it would be two arms fighting.
      if (panel.index == _source.controlPanelIndex) continue;
      if (!panel.established) continue;
      target = panel;
      break;
    }
    if (target == null) return;

    for (final key in _source.freshnessKeys) {
      if (key.startsWith(pipeKeyPrefix)) continue;
      final plant = _source.plantTruthFor(key);
      final live = target.read(key);
      if (plant == null || live == null) continue;
      if (plant.overridden || plant.sweepIndex == null) continue;
      if (live.quality != Quality.good) continue;

      // Arm A's outcome, exactly: the number the panel held before the frame it
      // never received, under the good quality it was carrying at the time.
      // Twenty sweeps back is five seconds of plant — past every allowance by a
      // factor of twenty, so the control cannot be mistaken for a timing
      // artifact.
      final superseded = DynamicValue(
          value: plant.sweepIndex! - _controlLagSweeps,
          quality: Quality.good);
      _controlFired = true;
      _controlTarget = '${target.name}|$key';
      final reading = _Reading(
        panelIndex: target.index,
        key: key,
        client: superseded,
        plant: plant,
        converged: false,
        generation: target.pageRebuilds,
        previousGeneration: target.pageRebuilds,
        complaints: target.complaints.length,
      );
      final open = _OpenDivergence(
        reading: reading,
        windowIndex: windowIndex,
        judgedAt: clock.elapsed,
        judgedAtSchedule: at,
      )
        // The rebuild the tick-sequence detector performs, which is what makes
        // this a `lostPush` rather than an `unattributed`: the control asserts
        // the ATTRIBUTION as well as the recording, so a taxonomy that stopped
        // attributing would fail here rather than print a clean verdict.
        ..generationWhileOpen = target.pageRebuilds + 1
        ..complaintsWhileOpen = target.complaints.length;
      ledger.record(DivergenceEvent(
        nth: ++_emitted,
        panelId: target.name,
        subId: defaultPageSubscription,
        key: key,
        scheduleOffset: at,
        wallOffsetMs: clock.elapsed.inMilliseconds,
        cause: _attribute(open: open, panel: target),
        healedWithinMs: null,
        clientValue: superseded.value,
        plantValue: plant.value,
        clientQuality: superseded.quality,
        plantQuality: plant.quality,
        generation: open.generationWhileOpen,
        windowIndex: windowIndex,
        isControl: true,
      ));
      return;
    }
  }

  /// How far behind the control's substituted reading sits, in sweeps.
  static const int _controlLagSweeps = 20;

  /// Which panel-and-key the control lied about, for a case to assert against.
  String? get controlTarget => _controlTarget;

  /// Whether the control fired.
  bool get controlFired => _controlFired;

  // ------------------------------------------------------- the run-end pass

  @override
  void finish() {
    try {
      if (_currentWindow >= 0) {
        _judgeWindowEnd(_clockAtFinish(), _currentWindow);
        _currentWindow = -1;
      }

      // Everything still open at the end of the run never healed: it survived
      // the window in which the timeline guaranteed nothing was armed, and
      // then survived everything after it. That is residue.
      for (final id in _open.keys.toList()) {
        final open = _open.remove(id)!;
        SoakPanelResyncView? panel;
        for (final one in _source.panelResyncViews) {
          if (one.index == open.reading.panelIndex) panel = one;
        }
        if (panel == null) continue;
        _emit(open: open, panel: panel, healedWithinMs: null);
      }

      if (_source.declaredDuration >= minDurationForAStableWindow &&
          _source.stableWindows.isEmpty) {
        violationLog.add(SoakViolation(
          checker: name,
          monotonic: _source.scheduleOffset,
          scheduleOffset: _source.scheduleOffset,
          observed: 0,
          expected: minimumSamplesForAVerdict,
          detail: 'this run generated ZERO stable windows against a floor of '
              '$minimumSamplesForAVerdict, so invariant 3 judged nothing and '
              'its green is not evidence. The windows are computed from the '
              'duration alone by computeStableWindows, and a '
              '${_source.declaredDuration.inSeconds}-second arm is above the '
              '${minDurationForAStableWindow.inSeconds}-second floor at which '
              'they start being generated — so this is a TIMELINE problem and '
              'not a checker one: the fix is the quiet-window cadence in '
              'soak_timeline.dart, and it carries its own reproducibility '
              'proof to re-run',
        ));
      }

      if (_controlDivergences.isNotEmpty) {
        violationLog.add(SoakViolation(
          checker: name,
          monotonic: _source.scheduleOffset,
          scheduleOffset: _source.scheduleOffset,
          panel: 'panel-${_source.controlPanelIndex}',
          observed: _controlDivergences.length,
          expected: 0,
          detail: 'the never-faulted control panel was still out of step with '
              'plant truth at the END of ${_controlDivergences.length} '
              'window(s) the storm never disturbed: '
              '${_controlDivergences.take(5).join('; ')}. The storm cannot aim '
              'at this panel — buildTimeline is given the other four names — '
              'so a divergence here in an undisturbed window is the gateway '
              'punishing a healthy panel, which is the pre-07-08b bug class',
        ));
      }
    } catch (error) {
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: _source.scheduleOffset,
        scheduleOffset: null,
        detail: 'the run-end pass threw, so the last window was not judged and '
            'its residue is unrecorded: $error',
      ));
    }
  }

  SoakClock _clockAtFinish() => SoakClock.frozenAt(_source.scheduleOffset,
      declaredDuration: _source.declaredDuration);

  // ----------------------------------------------------------- the report

  /// The measurement [minStableWindow] is judged against, printed every run.
  ///
  /// **N = 10 s was a hypothesis, not a constant to inherit** — 11-PLAN-INDEX
  /// assumption A4 says so, and `soak_timeline.dart` says it at the constant.
  /// The derivation was: the per-subscription staleness limit is `tickMs x 30`
  /// and the ordinary tick is 50-100 ms, so 1.5-3 s covers detection and a
  /// resync round trip on a recovered link is sub-second, leaving better than
  /// 3x margin at ten seconds.
  ///
  /// **That derivation left out the reconnect backoff, and the backoff
  /// dominates.** What is printed here is the observed in-window convergence
  /// time — how long a key that was out of step at a window's start took to
  /// come back into step — and the lane run that first produced it measured
  /// **p50 9251 ms, p95 9498 ms against a 10,000 ms window**. A panel whose
  /// link the storm cut does not resync as soon as the fault clears: it waits
  /// out an exponential backoff with full jitter capped at thirty seconds
  /// (`ClientConfig`), and only then hellos, subscribes and takes a snapshot.
  /// So the quantity the window has to cover is *backoff plus resync*, not
  /// resync alone.
  ///
  /// **[marginNote] says what that means for this arm**, on every run, green
  /// or red, because the margin is the number that decides whether residue is
  /// evidence or noise.
  /// How many DISTINCT values the three distributions retain between them.
  ///
  /// The number that must not scale with [keysCompared]. See [LagTally].
  int get retainedSamples =>
      _lagInWindow.retained + _convergenceMs.retained + _postWindowHealMs.retained;

  /// How many key comparisons this checker has made. The denominator
  /// [retainedSamples] must not scale with.
  int get keysCompared => _keysComparedTotal;

  String get convergenceReport {
    return <String>[
      '  eventualResync: $_windowsJudged windows judged against a floor of '
          '$minimumSamplesForAVerdict '
          '(${_source.stableWindows.length} generated), '
          '$_keysComparedTotal key comparisons',
      '    in-window convergence (ms): ${_convergenceMs.quantiles}',
      '    $marginNote',
      '    lag while judging (sweeps): ${_lagInWindow.quantiles} '
          'against an allowance of $convergedLagSweeps',
      '    healed after the window (ms): ${_postWindowHealMs.quantiles}',
      '    control panel (panel-${_source.controlPanelIndex}): '
          '${_controlDivergences.length} divergences at the end of undisturbed '
          'windows',
    ].join('\n');
  }

  /// How much of the window the slowest legitimate recovery used.
  ///
  /// Printed rather than asserted, deliberately. A margin that had to stay
  /// above a number would be a second invariant nobody declared, and the
  /// honest thing to do with a measurement that is uncomfortable is to keep
  /// printing it — 11-05's spread reports are the precedent.
  String get marginNote {
    final window = _source.stableWindows.isEmpty
        ? minStableWindow
        : _source.stableWindows.first.length;
    if (_convergenceMs.isEmpty) {
      return 'window margin: nothing needed to converge inside a window, so '
          'this run says nothing about whether '
          '${window.inMilliseconds}ms is enough';
    }
    final slowest = _convergenceMs.max;
    final used = (slowest * 100 / window.inMilliseconds).round();
    return 'window margin: the slowest recovery used $used% of this arm\'s '
        '${window.inMilliseconds}ms window. Above about 90% the window is too '
        'short to tell residue from a panel that had not finished its '
        'reconnect backoff, and the residue count stops being evidence';
  }

  @override
  String toString() => convergenceReport;
}

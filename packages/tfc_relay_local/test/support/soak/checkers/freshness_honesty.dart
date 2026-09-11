/// Invariant 1 — **no value is rendered as fresh whose age exceeds its
/// deadline.**
///
/// **The claim is about the verdict, not about the age.** A checker that
/// asserted "no value was older than X" would measure a different and weaker
/// thing: values go legitimately old all the time — a blackholed link, a PLC
/// mid-download, a quiet window — and the pipe is *correct* while that happens
/// so long as it says so. What CLAUDE.md's Core Value forbids is the panel
/// showing a five-minute-old tank level as current. So this samples the
/// **verdict** first and only then checks the age behind it, and getting that
/// the right way round is the whole design.
///
/// **What "the panel reports it fresh" means here.** CLI-04's three states, all
/// three of which a widget renders and all three of which have to say *fresh*
/// before this checker treats the reading as a claim of currency:
///
///  * `RemoteStateMan.viewIsStale` — the link has gone a whole
///    `ClientConfig.freshnessDeadline` without a frame of any kind.
///  * `RemoteStateMan.isSubscriptionStale(page)` — this page's plant-side
///    source has stopped being re-evaluated. Live, computed on read, so a
///    saturated link delivering old frames cannot agree with itself for ever
///    (07-RESEARCH §B.4).
///  * the value's own `Quality` — the gateway's `FreshnessSweep` degrades a key
///    to `Quality.badStale` once it is past `staleAfter`.
///
/// Any one of them dissenting is the panel being honest about doubt, and is
/// counted in [staleSamples] rather than judged as a lie.
///
/// **The age is measured against the monotonic anchor at last-frame-arrival,
/// and there is no wall clock in this file.** That is 07-REVIEW CR-01's
/// standing lesson and this milestone has now caught it four times (Phase 8
/// CR-01/CR-02, Phase 9 WR-01, Phase 10 WR-02). [SoakClock] hands out monotonic
/// elapsed time and nothing else, so the arithmetic below cannot be stepped by
/// an NTP correction even by accident — `invariant.dart` made it unreachable
/// rather than forbidden, and freeze 9 sweeps the spelling out of the tree.
///
/// What counts as an arrival is a **change in the rendered triple** — value,
/// quality and source time. The soak's plant moves every key of every link
/// every 250 ms with a monotonically increasing number (`GateBPlantDriver`), so
/// every key genuinely changes on every sweep and "when did this panel last
/// hear about this key" is a question the render surface can answer without
/// reaching into the client.
///
/// **Health keys are excluded by prefix, never by a list.** [PipeKeys.isPipeKey]
/// — the same predicate 08-05 task 3 owns and proved with a key called
/// `PIPE.invented.later`. 06-SUMMARY records what an enumerated list costs:
/// applying freshness accounting to `PIPE.cert.days_to_expiry`, which changes
/// once a day, *"greys out the indicator permanently and precisely while
/// nothing is wrong."* A second spelling of the prefix is the drift 08-04's
/// freeze exists to prevent.
///
/// **The 25 ms cadence is inherited, not chosen.**
/// `flap_gate_test.dart:55-160`: *"a sampler that took one reading per up-window
/// could miss the flicker the row is named for"*. A one-second flap half is the
/// fastest thing this storm produces. The cost is stated rather than hidden:
/// five panels x their subscribed keys x forty samples a second is the soak's
/// dominant per-tick expense, and it is the reason the herd default is 5 rather
/// than gate A's 20 (11-RESEARCH A6). If a run shows the sampler is cheap,
/// raising the population is a later decision with a measurement behind it.
library;

import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';

import '../../../soak/soak_registry.dart';
import '../invariant.dart';
import '../soak_observables.dart';

/// Judged readings per minute below which this checker's green is not
/// evidence.
///
/// **Four thousand eight hundred, which is one per cent of the theoretical
/// rate, and the derivation matters more than the number.** A 25 ms sampler is
/// 2,400 passes a minute; the soak's five panels each subscribe forty plant
/// keys, so a minute of unobstructed sampling is `2400 x 5 x 40` = **480,000**
/// judgeable readings. A floor at one per cent of that survives a hosted runner
/// that lost nine tenths of its timer slices, a herd down to one panel, and a
/// storm that blackholed the rest — while still failing instantly for the two
/// things a floor is for: a sampler that stopped, and a run where no
/// subscription ever established.
///
/// A tighter floor would be a better instrument and a worse one at the same
/// time: the failure it would add is "the runner was slow", which is not an
/// invariant and which nobody can act on at 07:00. The measured figure from the
/// ninety-second lane run is in 11-04's SUMMARY next to this number, so the
/// margin is a fact rather than a hope.
const int freshnessFloorPerMinute = 4800;

/// How long the control's view may stay stale before that is a finding
/// whatever the storm played.
///
/// **Ninety seconds, and it is the population floor's arithmetic reused.**
/// `populationFloorGraceDefault` argues seventy-five: a token revocation's
/// sixty-second restore window plus fifteen for the redial. The control is
/// never revoked — the storm cannot aim at it — so the longest legitimate
/// excursion it can suffer is a `GatewayRestart`, which is bounded by the
/// fixture's rebind budget and the panel's own backoff. Ninety is that with
/// room, and what it still catches is the one thing no number of plant-wide
/// arms excuses: a control that went stale and never came back.
const Duration controlStaleGraceDefault = Duration(seconds: 90);

/// One panel's last rendered state for one key, and when it arrived.
final class _Seen {
  _Seen(this.value, this.quality, this.sourceTime, this.arrivedAt);

  Object? value;
  Quality quality;
  DateTime? sourceTime;

  /// Monotonic elapsed at the moment the triple above last changed.
  Duration arrivedAt;
}

/// Invariant 1's instrument.
final class FreshnessHonestyChecker
    with GuardedSampling
    implements SoakRunEndCheck {
  FreshnessHonestyChecker(
    this.source, {
    Duration? declared,
    this.floorPerMinute = freshnessFloorPerMinute,
    this.controlStaleGrace = controlStaleGraceDefault,
  }) : _declaredOverride = declared;

  /// The panels, the keys and the budget. Never the client's internals.
  final SoakFreshnessSource source;

  /// A declared duration named at construction, for the unit arms that drive
  /// the floor without a driver behind them. Null in every lane run, where the
  /// source is the one that knows.
  final Duration? _declaredOverride;

  /// What the run was declared to be. The floor scales off this and never off
  /// measured elapsed time — `invariant.dart`'s rule, so a run that fell behind
  /// fails its floor rather than lowering it.
  Duration get declaredDuration =>
      _declaredOverride ?? source.declaredDuration;

  final int floorPerMinute;

  /// See [controlStaleGraceDefault].
  final Duration controlStaleGrace;

  @override
  final String name = freshnessHonesty;

  @override
  final ViolationLog violationLog = ViolationLog();

  /// Readings this checker could judge: one per (panel, non-health key) that
  /// had a value.
  ///
  /// Not sample calls. 11-01's third sabotage is why the distinction is spelled
  /// out on every checker in this phase: with the counter counting calls, a
  /// checker that threw on every call reported five readings against a floor of
  /// one and cleared the vacuity gate.
  @override
  int judgedSamples = 0;

  /// Readings where all three verdicts said *current*.
  int freshSamples = 0;

  /// Readings where at least one of them dissented. Honest, and counted so the
  /// run-end distribution can prove the storm reached the panels.
  int staleSamples = 0;

  /// [staleSamples] on the control panel, over the whole run. Reported rather
  /// than asserted — see [finish] for the two arms that are.
  int controlStaleSamples = 0;

  /// The same, counted only while the storm had played **no plant-wide arm**.
  int controlStaleSamplesBeforeAnyPlantWideArm = 0;

  /// The longest continuous stretch in which the control's view was stale.
  Duration controlWorstStaleStretch = Duration.zero;

  /// Distinct breaches — one per `(panel, key)` stretch over the budget.
  int freshnessEpisodes = 0;

  /// Ticks that re-observed an episode already recorded.
  int repeatsSuppressed = 0;

  /// Readings past the budget whose anchor was re-established by agreement
  /// with a pinned key's published value.
  ///
  /// Reported, never asserted. It is the honest measure of how often the
  /// arrival proxy could not answer and plant truth had to: a run where it
  /// dominates is a run whose freshness verdict rests more on the comparison
  /// than on the render surface, and the ledger should say so.
  int pinnedAnchorRefreshed = 0;

  /// `(panel, key)` pairs currently over the budget and already recorded.
  final Set<String> _episodes = <String>{};

  static String _episodeId(int panel, String key) => '$panel/$key';

  @override
  int get minimumSamplesForAVerdict => minimumSamplesForDuration(
        perMinute: floorPerMinute,
        declared: declaredDuration,
      );

  /// Panel index -> key -> what it last rendered and when.
  final Map<int, Map<String, _Seen>> _seen = <int, Map<String, _Seen>>{};

  Duration? _controlStaleSince;

  @override
  void takeReading(SoakClock clock) {
    final now = clock.elapsed;
    final budget = source.freshnessBudget;
    final control = source.controlPanelIndex;
    final beforeAnyPlantWideArm = source.plantWideArmsApplied == 0;

    for (final view in source.panelViews) {
      final panelDoubtsItself = view.viewIsStale || view.pageIsStale;
      if (view.index == control) _observeControlStretch(now, panelDoubtsItself);

      final seenHere = _seen.putIfAbsent(view.index, () => <String, _Seen>{});
      for (final key in source.freshnessKeys) {
        // By prefix, and this is the only place the decision is made. A value
        // in the gateway's own namespace changes on an event — a certificate
        // expiry once a day, a link state when a PLC drops — so freshness
        // accounting would report it stale exactly while nothing was wrong.
        if (PipeKeys.isPipeKey(key)) continue;

        final rendered = view.read(key);
        // Nothing has ever arrived for this key on this panel, in either of the
        // two shapes that says: no node at all, or the placeholder node a real
        // panel renders before its first snapshot lands.
        //
        // **Measured rather than anticipated.** The first composed run of this
        // checker recorded exactly 200 not-current readings on every panel of
        // every run — five 25 ms samples across forty keys — including on the
        // control, where they read as the soak's strongest arm tripping on
        // startup. What they were was `uncertainNotYetKnown` with a null value,
        // for the ~100 ms between the panels being declared ready and the first
        // snapshot arriving.
        //
        // The gateway's own sweep already draws exactly this line, and the
        // wording is its (`freshness_sweep.dart`): *"A key with no recorded
        // arrival is skipped. Nothing has ever come for it, so it is
        // `uncertainNotYetKnown` and not stale — those are different statements
        // and the second one implies the first was once true."* Counting the
        // placeholder would also let a run in which no subscription ever
        // established clear the vacuity gate on nothing but placeholders.
        if (rendered == null) continue;
        if (rendered.quality == Quality.uncertainNotYetKnown) continue;

        final seen = seenHere[key];
        if (seen == null) {
          seenHere[key] = _Seen(
              rendered.value, rendered.quality, rendered.sourceTime, now);
        } else if (seen.value != rendered.value ||
            seen.quality != rendered.quality ||
            seen.sourceTime != rendered.sourceTime) {
          seen
            ..value = rendered.value
            ..quality = rendered.quality
            ..sourceTime = rendered.sourceTime
            ..arrivedAt = now;
        }

        final renderedFresh =
            !panelDoubtsItself && rendered.quality == Quality.good;
        judgedSamples++;
        if (renderedFresh) {
          freshSamples++;
        } else {
          staleSamples++;
          if (view.index == control) {
            controlStaleSamples++;
            if (beforeAnyPlantWideArm) {
              controlStaleSamplesBeforeAnyPlantWideArm++;
            }
          }
        }
        if (!renderedFresh) continue;

        final age = now - (seenHere[key]?.arrivedAt ?? now);
        if (age <= budget) {
          _episodes.remove(_episodeId(view.index, key));
          continue;
        }

        // **A key the storm has PINNED is not judged on the arrival proxy, and
        // this is the narrowest form of that rule rather than an exclusion.**
        //
        // `PlantMutate` installs a raw override and `GateBPlantDriver._sweep`
        // then re-emits that one value every 250 ms for the rest of the run —
        // deliberately, because "a real device keeps reporting the new number
        // until something changes it" is what makes plant truth comparable at
        // all. The arrivals never stop; what stops is the render surface's
        // ability to SEE them, because an unchanged triple carries no evidence
        // of a re-emission. The premise stated at the top of this file — every
        // key changes on every sweep — is exactly what the override suspends.
        //
        // So the question is asked directly instead of through the proxy: is
        // the panel rendering the value the plant is publishing right now? If
        // it is, no operator is reading an old number, which is the property.
        // If it is not, the age still stands and the violation is still
        // recorded — a panel frozen on the pre-pin sweep counter while the
        // plant has moved on is precisely what this checker is for.
        //
        // Gated on `overridden`, which is the distinction `SoakPlantTruth`
        // already draws for invariant 3 ("overridden keys are judged on
        // equality"). Equality with a SWEPT key would prove nothing — the
        // counter is shared by every key on every link — and a rule that
        // accepted it would let a frozen plant silence this checker across the
        // board.
        //
        // **The anchor is REFRESHED rather than the reading skipped**, and the
        // difference is the size of the hole. Skipping would retire this key
        // from the arithmetic for the rest of the run — at seed 11 roughly ten
        // of the twelve storm keys end up pinned, so a fifth of the judged
        // surface would quietly stop being judged while the counters still
        // said it was. Refreshing keeps the reading in `judgedSamples` and in
        // `freshSamples` where it belongs, and it re-arms the arm: the moment
        // the plant is pinned to a NEW value the panel does not hold, the age
        // starts accumulating again from the last instant the two agreed.
        final plant = source.plantTruthFor(key);
        if (plant != null && plant.overridden && rendered.value == plant.value) {
          pinnedAnchorRefreshed++;
          seenHere[key]?.arrivedAt = now;
          _episodes.remove(_episodeId(view.index, key));
          continue;
        }

        // One breach observed on many ticks is one finding. Invariants 4 and 5
        // both latch (`ratioReported`, `overReported`); this was the one that
        // did not, and 11-06 measured what that cost: a single episode fanned
        // out over four panels and re-counted every 25 ms filled the violation
        // log's capacity of 200 and consumed all 25 printed slots on both
        // 35-minute runs, leaving two `boundedMemory` violations unidentified.
        if (!_episodes.add(_episodeId(view.index, key))) {
          repeatsSuppressed++;
          continue;
        }
        freshnessEpisodes++;
        violationLog.add(SoakViolation(
          checker: name,
          monotonic: now,
          scheduleOffset: source.scheduleOffset,
          panel: view.name,
          key: key,
          observed: '${age.inMilliseconds}ms since this panel last heard about '
              'the key',
          expected: 'at most ${budget.inMilliseconds}ms, or a verdict that '
              'says otherwise',
          detail: 'seed=${source.seed} — the panel rendered this value as '
              'CURRENT while its own last arrival for it was '
              '${age.inMilliseconds}ms ago. viewIsStale=${view.viewIsStale}, '
              'pageIsStale=${view.pageIsStale}, '
              'quality=${rendered.quality}. This is the failure '
              'PROJECT.md exists to prevent: an operator reading an old '
              'number as the plant\'s current state, with nothing on the '
              'screen saying otherwise',
        ));
      }
    }
  }

  void _observeControlStretch(Duration now, bool stale) {
    if (!stale) {
      _controlStaleSince = null;
      return;
    }
    final since = _controlStaleSince ??= now;
    final stretch = now - since;
    if (stretch > controlWorstStaleStretch) controlWorstStaleStretch = stretch;
  }

  /// The two whole-run questions: did the storm actually happen, and did the
  /// control survive the half of it that was never aimed at it.
  @override
  void finish() {
    // ---------------------------------------------------------- distribution
    //
    // Both directions, and each failing by name. A green freshness verdict from
    // a run where nothing ever went stale is a broken soak wearing a green
    // tick; one where nothing was ever fresh measured a dead pipe.
    if (staleSamples == 0) {
      _record(
        'staleSamples is ZERO over the whole run, so nothing this checker '
        'judged was ever reported as anything but current. The verdict above '
        'is therefore a description of a pipe the storm never reached rather '
        'than evidence that it stayed honest under one — read the applied '
        'entries and the per-panel dips in the same block',
        observed: 'staleSamples=0, freshSamples=$freshSamples',
        expected: 'staleSamples > 0',
      );
    }
    if (freshSamples == 0) {
      _record(
        'freshSamples is ZERO over the whole run, so no panel ever rendered '
        'anything as current. Nothing recovered, which means the invariant '
        'held against a pipe that was down rather than against one under '
        'weather',
        observed: 'freshSamples=0, staleSamples=$staleSamples',
        expected: 'freshSamples > 0',
      );
    }

    // ------------------------------------------------------- the control arms
    //
    // Two of them, and the split is the correction 11-03 wrote down: the
    // control's property is "the storm never AIMS at it", NOT "it is never
    // disturbed". `GatewayRestart`, `KeymappingReload` and every upstream arm
    // are plant-wide and reach the control like everybody else. An arm written
    // against the second reading would be the strongest instrument in the soak
    // turned flaky.
    if (controlStaleSamplesBeforeAnyPlantWideArm > 0) {
      _record(
        'the control panel reported $controlStaleSamplesBeforeAnyPlantWideArm '
        'readings as not-current while the storm had played NO plant-wide arm '
        '— so every fault in play at the time was panel-targeted, and the '
        'control is not a target. This is the pre-07-08b bug class: a gateway '
        'punishing healthy panels. An all-faulted population cannot see it; '
        'one healthy panel makes it glaring',
        panel: 'control',
        observed: controlStaleSamplesBeforeAnyPlantWideArm,
        expected: 0,
      );
    }

    if (controlWorstStaleStretch > controlStaleGrace) {
      _record(
        'the control panel\'s view was stale for '
        '${formatSoakOffset(controlWorstStaleStretch)} without a break and '
        'never came back inside its grace of '
        '${formatSoakOffset(controlStaleGrace)}. A plant-wide disturbance is '
        'transient — a gateway rebinds, a routing table re-ingests — so a '
        'control that does not recover is a finding no number of restarts '
        'excuses. ${source.plantWideArmsApplied} plant-wide arms were played',
        panel: 'control',
        observed: formatSoakOffset(controlWorstStaleStretch),
        expected: 'at most ${formatSoakOffset(controlStaleGrace)}',
      );
    }
  }

  void _record(String detail,
      {String? panel, Object? observed, Object? expected}) {
    violationLog.add(SoakViolation(
      checker: name,
      // The run has ended, so there is no meaningful instant to name and
      // `SoakViolation` requires the decision rather than defaulting it.
      monotonic: Duration.zero,
      scheduleOffset: source.scheduleOffset,
      panel: panel,
      observed: observed,
      expected: expected,
      detail: 'seed=${source.seed} — $detail',
    ));
  }

  /// The counters, for the verdict block and for `metrics.jsonl`.
  @override
  String toString() => '$name: $judgedSamples judged '
      '($freshSamples fresh, $staleSamples stale) against a floor of '
      '$minimumSamplesForAVerdict; control $controlStaleSamples stale '
      '($controlStaleSamplesBeforeAnyPlantWideArm before any plant-wide arm), '
      'worst control stretch ${formatSoakOffset(controlWorstStaleStretch)}; '
      '$freshnessEpisodes episodes ($repeatsSuppressed repeat ticks '
      'suppressed), $pinnedAnchorRefreshed anchors re-established by '
      'agreement with a pinned key';
}

/// Invariant 5 — **a flapping link cannot produce an unbounded log flood.**
///
/// # This invariant is aimed at a hole this repository already knows the shape
/// of
///
/// `ResyncEngine.complaints` is declared `final List<String> complaints =
/// <String>[]` (`resync_engine.dart:65`) — **uncapped, with no cap anywhere** —
/// and appended from six sites. What holds it down is a pair of per-tick
/// suppression maps Phase 7 added for the G1 fix
/// (`connection_supervisor.dart:251-252`), and **those maps are cleared on every
/// genuine reconnect** (`:1012-1013`) — deliberately, so a recovered page is not
/// refused the rebuild it needs.
///
/// The gateway's own source names the scenario a chaos soak produces, at
/// `connection_supervisor.dart:692-702`:
///
/// > *"`ResyncEngine._recover` failing leaves the subscription unestablished on
/// > purpose and does not unsubscribe server-side, so the gateway keeps pushing
/// > `u` frames for the rest of the socket's life — every one of them with all
/// > its handles unknown, every one of them restarting the recovery that just
/// > failed, **each with another complaint on an unbounded list**."*
///
/// The only thing standing between that sentence and a flood is
/// `state.lastSeq != null`. A thirty-five-minute storm that flaps a link
/// hundreds of times, clearing the suppression maps every time, is the most
/// likely thing in this repository to find the hole in that guard. This checker
/// exists to catch it if it is there and to leave a measured number behind if it
/// is not.
///
/// # What a complaint actually is, measured — and the premise this corrects
///
/// 11-05's plan asserts *"`complaints.length > 0` at run end. A storm that
/// produced no complaints at all means the panels never lost a subscription,
/// which for a flap storm means the faults did not reach them."* **The first
/// step of that inference is false, and the lane measured it.** Five
/// ninety-second runs at seed 11 produced 2–8 readiness dips per storm-targeted
/// panel and **zero complaints in the whole herd, every run.**
///
/// The cause is in the append sites rather than in the storm. There are three,
/// all in `resync_engine.dart`, and every one of them needs a re-establishment
/// that went **wrong**:
///
/// - `:208` — inside `_recover`'s `catch`. The `subscribe` threw.
/// - `:249` — one per key the gateway returned in `SubscribeResult.rejected`
///   (`_classify`, `session_handlers.dart:303`: an empty key or one this source
///   does not serve).
/// - `:252` — `result.complaints`, whatever the gateway chose to say.
///
/// An ordinary flap — socket dies, backoff, reconnect, resubscribe succeeds —
/// appends **nothing**. That is the pipe working, and it is the common case.
/// So a run with zero complaints is not evidence of a broken soak; it is
/// evidence that every rebuild the storm forced actually rebuilt.
///
/// The anti-vacuity gate is therefore written against the condition that makes
/// the complaint path *reachable*, which is [SoakPanelLogView.reestablishments]
/// — see [BoundedLogsChecker.reestablishments] and
/// [boundedLogsExercisedFloor]. The complaint total is printed on every run and
/// asserted against zero on none.
///
/// # Why the verdict is a rate and not a total
///
/// A total over thirty-five minutes is either so loose it never fires or so
/// tight that a legitimately noisy storm burst trips it — and the two are the
/// same number seen from different runs, which is why nobody can pick it. The
/// primary verdict is therefore **complaints per minute per panel**, measured
/// over a sliding [boundedLogsRateWindow] and sampled at every checkpoint,
/// against [boundedLogsCeilingPerMinute]. The absolute total is a second,
/// **sustained** allowance ([boundedLogsTotalBackstopPerMinute]) for the one
/// thing a burst ceiling cannot see: a list that grows steadily, slowly and for
/// ever. It sits *below* the burst ceiling rather than above it, and the
/// constant says why.
///
/// Measured, under the sabotage the plan asked for: replacing the rate with an
/// absolute total made a genuine one-window burst — 30 complaints in 30 s, 60 a
/// minute — **stop being recorded at all**, while a slow drift to the same
/// total fired. The verdict had become a statement about how long the run was.
/// That pair of outcomes is the argument for a rate.
///
/// The ceiling is **derived and not chosen**, and the derivation had to change
/// shape because the measured p95 came back zero. Both anchors are on the
/// constant. `GATE_LANE_BUDGET`'s 480 s is the precedent for how a number like
/// this is declared and argued in this repository.
///
/// # Do not raise the gateway's log level to get better forensics
///
/// It changes what is being measured, and it would trip this ceiling itself.
/// `package:logger` at `trace` with `PrettyPrinter` is measured in this project
/// at seconds of lag per burst (PR #210), which is why
/// `relay_gateway.dart:44-46` says in so many words that *"a gateway logs
/// conditions, not events"* and pins `Level.info`. This is the file where
/// somebody would think of turning it up, so it says so here.
///
/// # The two halves, and both are real
///
/// **Client side** is [SoakPanelLogView.complaints], the uncapped list itself.
///
/// **Server side** is [SoakLogSource.gatewayLogLines] — and it is a genuine
/// log-line count rather than a stand-in. `buildGateway`'s default error sink is
/// `_logServerError(log)`, `(error, stack, where) => log.e('[server] $where:
/// $error')` at `gateway_config.dart:492-497`, installed at `:643`. The soak
/// occupies that same injectable seam with a collector
/// (`gate_b_fixture.dart:656`), so one collected entry is exactly one line the
/// deployed gateway would write. No subprocess harness was needed and no
/// deviation was taken: the `[MT-6]` re-read's stop condition — *"if the gateway
/// only writes to stdout"* — does not hold. `package:logger` and stdout appear
/// only in `bin/relay_gateway.dart`, which composes the seam this fixture
/// occupies, and which the soak does not run.
///
/// [SoakLogSource.plantIngestLogLines] is the second server-side surface and the
/// closest structural twin of the client damping this invariant's control
/// removes: `IngestLog` damps to **once per key per process** precisely because
/// *"a struct that fails at 10 Hz writes 864,000 identical lines a day"*
/// (`ingest.dart:96-101`).
///
/// # The shared observable
///
/// `complaints.length` is watched by invariant 4 as well, which asks whether the
/// list grows without bound where this one asks whether it grows too fast inside
/// a window. A genuine flood trips both, and that is correct — but the report
/// must not present it as two independent findings corroborating each other
/// (pitfall 8). `soak_test.dart`'s verdict block prints the
/// one-finding-two-instruments sentence when both record against this observable
/// in the same checkpoint.
library;

import '../../../soak/soak_registry.dart';
import '../invariant.dart';
import '../soak_observables.dart';

// --------------------------------------------------------------- the numbers

/// The window a rate is measured over.
///
/// One minute, which is the unit the ceiling is quoted in, so the number in the
/// failure message and the number in the constant are the same number. A shorter
/// window would make a single burst read as a sustained rate; a longer one would
/// let a real flood hide inside a quiet half-hour.
const Duration boundedLogsRateWindow = Duration(minutes: 1);

/// The shortest span a rate may be computed over.
///
/// **Twenty seconds.** At the five-second checkpoint cadence the sliding window
/// is empty for the first reading and thin for the next three, and a rate
/// extrapolated from a five-second span multiplies whatever noise is in it by
/// twelve. Below this span the panel's window is not judged — which is a
/// vacuity statement, so it is subtracted from `judgedSamples` rather than
/// silently passed.
const Duration boundedLogsMinimumWindowSpan = Duration(seconds: 20);

/// How many complaints a minute one panel may produce. **The ceiling.**
///
/// **Twenty, and the derivation has two halves because the measured p95 is
/// zero.** The plan says to set this at a margin above the observed p95 across
/// five short runs. Those runs were taken and the distribution is degenerate:
/// five ninety-second runs at seed 11, five panels each, 274 judged windows
/// altogether, **every rate 0.0/min — p50, p95 and max are all zero.** A margin
/// above zero is any number at all, so a second anchor is needed and the honest
/// one is the failure this ceiling exists to catch.
///
/// **From below — the highest legitimate rate the surface can reach.** A
/// complaint costs a re-establishment that went wrong (see the library doc), so
/// the ceiling on legitimate complaints is the ceiling on rebuilds. Measured
/// across the same five runs, per panel: `panel-1` 2, 2, 5, 3, 4 dips and
/// `panel-4` 3 dips every run, over ninety seconds — a worst case of **3.3
/// rebuilds a minute**. If every single one of them failed and complained, that
/// is 3.3 complaints a minute. Twenty is **6x** that.
///
/// **From above — the rate the regression produces.** Phase 7's
/// `_resyncComplained` damping (`connection_supervisor.dart`) turns
/// "one complaint per resync tick" into "one per subscription per connection".
/// The shipping tick is 1500 ms, so removing it costs **40 complaints a minute**
/// per mismatching page, and the `u`-frame path at `:692-702` is faster still.
/// Twenty is **half** of 40, so the control trips the shipping number with 2x of
/// room rather than needing a tighter one passed in.
///
/// The window between the two anchors is 3.3 and 40. Twenty sits near the
/// geometric middle of it and is the number both arms are argued against.
const int boundedLogsCeilingPerMinute = 20;

/// The **sustained** rate, averaged over the whole run. The backstop.
///
/// **Ten a minute — deliberately BELOW the burst ceiling, which is the only way
/// it can see anything the rate cannot.** The first draft of this file made the
/// backstop 240/minute on the reasoning that a backstop should be "much looser".
/// It cannot be: a per-minute allowance looser than [boundedLogsCeilingPerMinute]
/// is unreachable by definition — anything fast enough to breach it has already
/// breached the ceiling — so the arm the doc describes as catching *"a list
/// growing steadily, slowly and for ever"* would never have fired.
///
/// The pair is a burst allowance and a sustained allowance: a panel may reach
/// 20/min inside any one minute, but may not average more than 10/min across the
/// declared run. Nineteen a minute for thirty-five minutes — under the ceiling
/// the whole way — is 665 complaints against a backstop of 350, and that is
/// exactly the failure this arm is for. In the ninety-second lane it is 15
/// against a measured 0, with the worst legitimate case (five rebuilds, all
/// failing) at 5.
const int boundedLogsTotalBackstopPerMinute = 10;

/// How many complaints the control panel may hold at the end of the run.
///
/// Measured, for the record: **0 across all five lane runs, with 0 readiness
/// dips** — the control is not merely unaimed-at, seed 11's ninety seconds never
/// disturb it at all. The threshold is not derived from that, because the
/// property it guards is a thirty-five-minute one.
///
/// **The arm that would have caught the pre-07-08b heartbeat bug** — a gateway
/// punishing healthy panels. Near-empty rather than empty, and the correction
/// 11-03 wrote down is why: `GatewayRestart`, `KeymappingReload` and every
/// upstream arm are plant-wide and reach the control like everybody else, so a
/// control that is *never disturbed* is not a property anything could hold. What
/// is a property is that the storm never AIMS at it, and a handful of complaints
/// from a plant-wide restart is the honest cost of that.
const int boundedLogsControlTotal = 12;

/// Judged windows per minute below which this checker's green is not evidence.
///
/// At a five-second cadence with five panels a minute offers sixty windows. The
/// floor is ten: it survives a herd down to one panel and a runner that lost
/// most of its timer slices, while failing instantly for a run in which no
/// panel ever established a session.
const int boundedLogsFloorPerMinute = 10;

/// The shortest declared run in which one window can exist at all.
///
/// **Twenty-five seconds: [boundedLogsMinimumWindowSpan] plus the checkpoint
/// that opens it.** Below this the arithmetic is not tight, it is impossible —
/// an eight-second run takes one checkpoint, and a rate needs two readings. A
/// floor of one against a physically unreachable reading is not an anti-vacuity
/// gate; it is a case that fails for the length of the arm rather than for
/// anything about the pipe.
///
/// So below this duration the checker declares itself **not measurable**, its
/// floor is zero, and [BoundedLogsChecker.measurable] prints false in the
/// verdict row — 11-04's `distributionWasAsked` shape, applied to a floor. The
/// exemption cannot hide, and neither real arm is anywhere near it: the lane is
/// ninety seconds and RES-03's is thirty-five minutes. What it exempts is
/// `soak_test.dart`'s auxiliary runs, which declare eight and twelve seconds to
/// prove things about seeds and repro logs.
const Duration boundedLogsMeasurableFrom = Duration(seconds: 25);

/// How many re-establishments the herd must have been put through for this
/// invariant's green to be evidence. **The anti-vacuity floor.**
///
/// **One, and it is a floor on rebuilds rather than on complaints.** See the
/// library doc for the measurement that moved it there: the complaint path runs
/// only inside a re-establishment that failed, so a run in which nobody ever
/// rebuilt could not have produced a complaint for a reason that has nothing to
/// do with whether the surface is bounded — and asserting `complaints > 0`
/// against that run fails the soak for the pipe working.
///
/// One rather than a per-minute rate, because the storm's rebuild count is a
/// property of the seed and the fault band and not of this invariant: seed 11
/// produces 5–8 across the herd in ninety seconds and 11-02 measured bands that
/// would produce far more. What this floor is for is the run in which the faults
/// reached nobody, and one rebuild is the whole of that distinction.
const int boundedLogsExercisedFloor = 1;

// ------------------------------------------------------------ one panel's window

/// One panel's sliding complaint window.
///
/// Bounded by the window rather than by the run: readings older than [span]'s
/// width are dropped as they age out, so a thirty-five-minute run holds twelve
/// readings a panel and not four hundred and twenty. The instrument must not be
/// the leak — 07-RESEARCH trap 15, and invariant 4 is watching this process too.
final class BoundedLogsWindow {
  BoundedLogsWindow(this.panel, this.width);

  /// `panel-N`.
  final String panel;

  /// How wide the sliding window is.
  final Duration width;

  final List<(Duration at, int complaints)> _readings =
      <(Duration, int)>[];

  /// The most recent complaint count, **summed across every incarnation of
  /// this panel's client**.
  ///
  /// See [push]. Not the live client's list length: that is reset by a redial,
  /// and this invariant is about the run.
  int last = 0;

  /// The highest per-minute rate this panel ever reached.
  double worstRate = 0;

  /// The offset [worstRate] was reached at.
  Duration worstAt = Duration.zero;

  /// How many windows were wide enough and established enough to judge.
  int judged = 0;

  /// How many times this panel has been made to rebuild. See
  /// [SoakPanelLogView.reestablishments].
  int reestablishments = 0;

  /// Whether the ceiling breach in progress has already been recorded.
  ///
  /// Latched and cleared on the way back under, for `ViolationLog`'s reason: a
  /// panel stuck above the ceiling would otherwise record the same finding at
  /// every checkpoint until the log's two hundred slots were gone.
  bool overReported = false;

  /// What the CURRENT client incarnation had already contributed to [last].
  ///
  /// Reset to zero when the reading drops, which is the only signal a redial
  /// leaves: `ResyncEngine.complaints` only ever grows within one client.
  int _incarnationBase = 0;

  /// Records one reading and ages out everything past [width].
  ///
  /// **The reading is accumulated across incarnations rather than stored**,
  /// and that is not book-keeping — it is what makes this window measure the
  /// run. `SoakLogSource.panelLogs` reads the LIVE `RemoteStateMan`
  /// (`soak_driver.dart:2144`), and `GateBFixture.redial` replaces it outright
  /// on every `TokenRestore` (`:1889`), so the raw count drops to zero
  /// mid-run. `reestablishments` does not — `_health[i]` is created once at
  /// `start()` — so storing the raw count let the anti-vacuity gate survive a
  /// reset that destroyed the quantity being judged. That asymmetry is what
  /// made it a defect rather than noise.
  ///
  /// Two arms depended on the difference. The **ceiling**: a forty-complaint
  /// flood followed by a redial gives `last - oldest` a negative value, so
  /// `rate <= ceilingPerMinute` holds, `overReported` is cleared, and the
  /// window still counts toward `judgedSamples` — a flood erased and a green
  /// rate reported over a judged window. The **backstop**: "a list growing
  /// steadily, slowly and for ever" is its stated purpose, and it cannot be
  /// seen across a redial if the run's total is never held anywhere.
  ///
  /// A total that only ever increases also makes [ratePerMinute] a rate. A
  /// negative one was never a rate; it was the instrument being replaced
  /// mid-measurement.
  void push(Duration at, int complaints) {
    if (complaints < _incarnationBase) _incarnationBase = 0;
    last += complaints - _incarnationBase;
    _incarnationBase = complaints;
    _readings.add((at, last));
    while (_readings.length > 1 && at - _readings.first.$1 > width) {
      _readings.removeAt(0);
    }
  }

  /// How much time the retained readings cover.
  Duration get span =>
      _readings.isEmpty ? Duration.zero : _readings.last.$1 - _readings.first.$1;

  /// The run total at the far end of the window. See [push].
  int get oldest => _readings.isEmpty ? 0 : _readings.first.$2;

  /// Complaints a minute across the retained window, or null if it is empty.
  double? get ratePerMinute {
    final covered = span;
    if (covered <= Duration.zero) return null;
    return (last - oldest) * 60000 / covered.inMilliseconds;
  }

  @override
  String toString() =>
      '$panel: $last complaints across every incarnation, worst '
      '${worstRate.toStringAsFixed(1)}/min at '
      '${formatSoakOffset(worstAt)} over $judged judged windows, '
      '$reestablishments rebuilds';
}

// ------------------------------------------------------------- the instrument

/// Invariant 5's instrument.
final class BoundedLogsChecker with GuardedSampling implements SoakRunEndCheck {
  BoundedLogsChecker(
    this.source, {
    Duration? declared,
    this.ceilingPerMinute = boundedLogsCeilingPerMinute,
    this.window = boundedLogsRateWindow,
    this.minimumWindowSpan = boundedLogsMinimumWindowSpan,
    this.totalBackstopPerMinute = boundedLogsTotalBackstopPerMinute,
    this.controlTotal = boundedLogsControlTotal,
    this.floorPerMinute = boundedLogsFloorPerMinute,
    this.exercisedFloor = boundedLogsExercisedFloor,
  }) : _declaredOverride = declared;

  /// The panels' complaint surfaces and the gateway's line count.
  final SoakLogSource source;

  final Duration? _declaredOverride;

  /// What the run was declared to be — `invariant.dart`'s rule.
  Duration get declaredDuration => _declaredOverride ?? source.declaredDuration;

  final int ceilingPerMinute;
  final Duration window;
  final Duration minimumWindowSpan;
  final int totalBackstopPerMinute;
  final int controlTotal;
  final int floorPerMinute;

  /// See [boundedLogsExercisedFloor].
  final int exercisedFloor;

  @override
  final String name = boundedLogs;

  @override
  final ViolationLog violationLog = ViolationLog();

  /// Windows this checker could judge: one per (panel, checkpoint) where the
  /// panel was established and the window was wide enough.
  ///
  /// Not `sample` calls, and not checkpoints. 11-01's third sabotage is why.
  @override
  int judgedSamples = 0;

  /// Per-panel windows, keyed by panel index.
  final Map<int, BoundedLogsWindow> windows = <int, BoundedLogsWindow>{};

  /// The gateway's line count at the last reading.
  int gatewayLogLines = 0;

  /// The plant's damped ingest-refusal line count at the last reading.
  int plantIngestLogLines = 0;

  /// Whether the declared run is long enough to contain one window.
  ///
  /// See [boundedLogsMeasurableFrom]. Printed either way.
  bool get measurable => declaredDuration >= boundedLogsMeasurableFrom;

  /// How many times the herd was made to rebuild, summed across the panels.
  ///
  /// The anti-vacuity observable. See [boundedLogsExercisedFloor] and the
  /// library doc's measurement.
  int reestablishments = 0;

  /// Whether the storm made anybody rebuild, so the complaint path was
  /// reachable at all.
  ///
  /// Exempt below [boundedLogsMeasurableFrom] for the same reason the sample
  /// floor is: an eight-second run may legitimately flap nobody, and a case
  /// that fails for the length of the arm is not an anti-vacuity gate.
  bool get surfaceWasExercised =>
      !measurable || reestablishments >= exercisedFloor;

  @override
  int get minimumSamplesForAVerdict => measurable
      ? minimumSamplesForDuration(
          perMinute: floorPerMinute,
          declared: declaredDuration,
        )
      : 0;

  /// The backstop, scaled to the declared duration.
  int get totalBackstop => minimumSamplesForDuration(
        perMinute: totalBackstopPerMinute,
        declared: declaredDuration,
      );

  @override
  void takeReading(SoakClock clock) {
    final now = clock.elapsed;
    gatewayLogLines = source.gatewayLogLines;
    plantIngestLogLines = source.plantIngestLogLines;

    var rebuilds = 0;
    for (final view in source.panelLogs) {
      rebuilds += view.reestablishments;
      final panel = windows.putIfAbsent(
          view.index, () => BoundedLogsWindow(view.name, window))
        ..push(now, view.complaints)
        ..reestablishments = view.reestablishments;

      // A panel that never connected produced no complaints for a reason that
      // is not this invariant's, and a window five seconds wide extrapolates
      // whatever noise is in it by twelve. Neither is judged, and neither is
      // silently passed either: both simply do not advance `judgedSamples`, so
      // a run made of nothing but thin windows fails the vacuity gate.
      if (!view.established) continue;
      if (panel.span < minimumWindowSpan) continue;

      final rate = panel.ratePerMinute;
      if (rate == null) continue;
      judgedSamples++;
      panel.judged++;
      if (rate > panel.worstRate) {
        panel.worstRate = rate;
        panel.worstAt = now;
      }

      if (rate <= ceilingPerMinute) {
        panel.overReported = false;
        continue;
      }
      if (panel.overReported) continue;
      panel.overReported = true;
      violationLog.add(SoakViolation(
        checker: name,
        monotonic: now,
        scheduleOffset: source.scheduleOffset,
        panel: view.name,
        key: 'complaints',
        observed: '${rate.toStringAsFixed(1)} complaints per minute',
        expected: 'at most $ceilingPerMinute per minute',
        detail: 'seed=${source.seed} — over the '
            '${panel.span.inSeconds}s window ending at '
            '${formatSoakOffset(now)} this panel added '
            '${panel.last - panel.oldest} complaints, a rate of '
            '${rate.toStringAsFixed(1)} per minute against a ceiling of '
            '$ceilingPerMinute. ResyncEngine.complaints is uncapped '
            '(resync_engine.dart:65) and the suppression maps that damp it are '
            'cleared on every genuine reconnect '
            '(connection_supervisor.dart:1012-1013), so a storm that flaps a '
            'link hundreds of times is the thing most likely to find the hole '
            'in that guard. Invariant 4 watches the same list as a slope — if '
            'it recorded too, this is ONE finding seen by two instruments',
      ));
    }
    // Monotone by construction (`readyDips` only ever increments), but taken as
    // a maximum rather than assigned, so a redial that hands back a fresh
    // health record cannot walk the run's own count backwards.
    if (rebuilds > reestablishments) reestablishments = rebuilds;
  }

  /// Every complaint total, summed across the herd.
  int get totalComplaints =>
      windows.values.fold(0, (sum, one) => sum + one.last);

  /// The whole-run questions: did the storm produce any complaint at all, did
  /// anybody drift past the backstop, and did the control stay near-empty.
  @override
  void finish() {
    // -------------------------------------------------------- anti-vacuity
    //
    // The question is whether the complaint PATH was reachable, not whether it
    // was taken. `complaints > 0` was this arm's first shape and the lane
    // refuted it: an ordinary flap that reconnects and resubscribes cleanly
    // appends nothing, so five green runs produced 5-8 rebuilds and zero
    // complaints between them. Asserting a non-zero list would have failed the
    // soak for the pipe working. See the library doc for the three append sites
    // and the measurement.
    if (!surfaceWasExercised) {
      _record(
        'the storm never made a single panel rebuild over the whole run, so '
        'this ceiling held against a surface nothing ever exercised. Every '
        'append site on ResyncEngine.complaints is inside a re-establishment '
        'that went wrong (resync_engine.dart:208, :249, :252) — no rebuild, no '
        'reachable path, and a green row that means nothing. For a flap storm '
        'it also means the faults did not reach anybody, which is a broken '
        'soak wearing a green tick',
        observed: reestablishments,
        expected: 'at least $exercisedFloor',
      );
    }

    // ------------------------------------------------------------ the backstop
    for (final panel in windows.values) {
      if (panel.last <= totalBackstop) continue;
      _record(
        '${panel.panel} finished with ${panel.last} complaints against a '
        'backstop of $totalBackstop for a $declaredDuration run, at a rate '
        'the ceiling of $ceilingPerMinute per minute never noticed (worst '
        '${panel.worstRate.toStringAsFixed(1)}). That combination IS the '
        'finding: a list growing steadily, slowly and for ever is the one '
        'failure a rate cannot see, and it is invariant 4\'s language as much '
        'as this one\'s',
        panel: panel.panel,
        observed: panel.last,
        expected: 'at most $totalBackstop',
      );
    }

    // ---------------------------------------------------------- the control
    final control = windows[source.controlPanelIndex];
    if (control != null && control.last > controlTotal) {
      _record(
        'the control panel holds ${control.last} complaints against a '
        'threshold of $controlTotal. The storm may never AIM at this panel — '
        'plant-wide arms reach it like everybody else and a handful of '
        'complaints from a gateway restart is their honest cost, but this is '
        'past that. It is the arm that would have caught the pre-07-08b '
        'heartbeat bug: a gateway punishing healthy panels',
        panel: control.panel,
        observed: control.last,
        expected: 'at most $controlTotal',
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
      key: 'complaints',
      observed: observed,
      expected: expected,
      detail: 'seed=${source.seed} — $detail',
    ));
  }

  /// The per-panel rate distribution, for the SUMMARY and for a red run.
  ///
  /// This is where the ceiling comes from. It prints on a green run too,
  /// because a green run's distribution is the only evidence anybody has that
  /// the number was measured rather than picked.
  String get spreadReport => <String>[
        'boundedLogs rates over a ${window.inSeconds}s window '
            '(ceiling $ceilingPerMinute/min, backstop $totalBackstop total):',
        for (final index in (windows.keys.toList()..sort()))
          '  ${windows[index]}'
              '${index == source.controlPanelIndex ? '   [CONTROL]' : ''}',
        '  gateway log lines $gatewayLogLines, plant ingest log lines '
            '$plantIngestLogLines',
        '  $reestablishments rebuilds across the herd against a floor of '
            '$exercisedFloor — the anti-vacuity observable, because a complaint '
            'costs a re-establishment that went wrong and never an ordinary one',
      ].join('\n');

  @override
  String toString() {
    final worst = windows.values.isEmpty
        ? null
        : (windows.values.toList()
              ..sort((a, b) => b.worstRate.compareTo(a.worstRate)))
            .first;
    return '$name: $judgedSamples judged windows against a floor of '
        '$minimumSamplesForAVerdict'
        '${measurable ? '' : ' (NOT MEASURABLE at a declared $declaredDuration '
            '— one window needs $boundedLogsMeasurableFrom, so the floor is '
            'exempt and this run is not evidence)'}'
        '; $reestablishments rebuilds (floor $exercisedFloor)'
        '; $totalComplaints complaints across the '
        'herd, worst ${worst == null ? 'n/a' : '${worst.worstRate.toStringAsFixed(1)}/min '
            'on ${worst.panel} at ${formatSoakOffset(worst.worstAt)}'} against '
        'a ceiling of $ceilingPerMinute; control '
        '${windows[source.controlPanelIndex]?.last ?? 0} of $controlTotal; '
        'gateway $gatewayLogLines lines, plant ingest $plantIngestLogLines';
  }
}

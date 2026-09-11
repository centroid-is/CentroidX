/// The checkers' own instruments, proved against fixtures rather than against
/// a storm — and the positive controls that make each of them fail on demand.
///
/// **Why this file exists next to `soak_test.dart`.** A checker is an
/// instrument, and an instrument nobody has ever seen deflect is a green tick
/// with no warrant behind it. `soak_test.dart` runs the storm and asserts the
/// invariants hold; this file asserts that the things asserting them *can
/// report a breach*. 11-01's whole argument about vacuity applies one level up:
/// an invariant that cannot fail and an invariant that held look identical in a
/// run report.
///
/// **Everything here is seconds-scale.** The unit arms drive the checkers
/// through the two narrow interfaces in `soak_observables.dart` with fixtures
/// that hold still, and the two arms that need a real pipe use
/// `SoakDriver.start()` without `play()` — a composed gateway, five real panels
/// over real sockets, and no thirty-five-minute storm behind it. A control that
/// costs a full run is a control somebody eventually stops running.
///
/// **What the fixtures are allowed to be.** A control replaces an *answer* and
/// never the stack that produced it. The live control below blackholes a real
/// panel through its real `FaultProxy`, lets the real client's real watchdog
/// notice, and then lies about exactly one verdict — which is the closest this
/// lane can get to 07-REVIEW CR-01's own defect. See [_LyingPanelView] for what
/// it is a substitute for and why the real thing is unavailable in CI.
@TestOn('vm')
@Tags(['soak'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_relay_client/tfc_relay_client.dart';
import 'package:tfc_relay_protocol/tfc_relay_protocol.dart';
import 'package:tfc_relay_server/tfc_relay_server.dart';

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

void main() {
  group('invariant 1: freshness honesty', () {
    test('a value rendered fresh past its deadline is a recorded violation',
        () {
      final source = _Source();
      final checker = FreshnessHonestyChecker(source);

      // Two readings a whole budget apart, with the value frozen in between and
      // the panel insisting the whole time that everything is current.
      source.panel(1).say('ST101.CN01.MOT01.setpoint', 7);
      checker.sample(SoakClock.frozenAt(Duration.zero,
          declaredDuration: const Duration(minutes: 1)));
      source.offset = const Duration(seconds: 40);
      checker.sample(SoakClock.frozenAt(const Duration(seconds: 40),
          declaredDuration: const Duration(minutes: 1)));

      expect(checker.violations, hasLength(1),
          reason: 'the panel said "fresh" about a value it had not heard '
              'about for forty seconds against a budget of '
              '${source.freshnessBudget}, and nothing recorded it');
    });

    test('the violation names the panel, the key, the schedule offset and the '
        'seed', () {
      final source = _Source(
          seed: 4242, keys: <String>['ST201.CN01.MOT01.setpoint'])
        ..offset = const Duration(minutes: 3, seconds: 20);
      final checker = FreshnessHonestyChecker(source);
      source.panel(2).say('ST201.CN01.MOT01.setpoint', 1);
      checker.sample(_at(Duration.zero));
      source.offset = const Duration(minutes: 4);
      checker.sample(_at(const Duration(seconds: 45)));

      final rendered = checker.violations.single.toString();
      for (final fragment in <String>[
        'panel-2',
        'ST201.CN01.MOT01.setpoint',
        '+04:00.000',
        '4242',
      ]) {
        expect(rendered, contains(fragment),
            reason: 'a trip record has to be quotable into an issue without '
                'the run that produced it. Missing "$fragment":\n$rendered');
      }
    });

    test('an honest stale verdict is counted and is never a violation', () {
      final source = _Source();
      final checker = FreshnessHonestyChecker(source);
      source.panel(1).say('ST101.CN01.MOT01.setpoint', 7);
      checker.sample(_at(Duration.zero));
      source.panel(1).viewIsStale = true;
      source.offset = const Duration(seconds: 40);
      checker.sample(_at(const Duration(seconds: 40)));

      expect(checker.violations, isEmpty,
          reason: 'the invariant is that the panel did not LIE, not that '
              'values were young: a panel showing a forty-second-old value '
              'with the link marked stale is telling the operator exactly '
              'what is true');
      expect(checker.staleSamples, greaterThan(0));
    });

    group('a key the storm has pinned to one value', () {
      // **The RES-03 red, and it was the instrument rather than the pipe.**
      //
      // `PlantMutate` does not write once — it installs a raw override, and
      // `GateBPlantDriver._sweep` then re-emits that ONE value on every 250 ms
      // poll cycle for the rest of the run, deliberately, because "a real
      // device keeps reporting the new number until something changes it" is
      // what makes plant truth a thing invariant 3 can compare against.
      //
      // This checker's arrival proxy is *a change in the rendered triple*, and
      // its own doc states the premise that makes the proxy sound: "the soak's
      // plant moves every key of every link every 250 ms with a monotonically
      // increasing number, so every key genuinely changes on every sweep".
      // **A pinned key is the one lever in the storm that breaks that
      // premise.** The re-emission is a genuine arrival the render surface
      // cannot see, so `arrivedAt` freezes while the gateway — which sees the
      // arrivals — correctly keeps the quality good.
      //
      // Measured, at seed 11 over thirty-five minutes: `[05:01.059] plant
      // BAADER.CN01.MOT03.setpoint=680` pins the key, and the first violation
      // is +05:12.377 at an age of 11275 ms — a last arrival of +05:01.102,
      // 43 ms after the pin. Four panels then re-counted the same frozen
      // arrival every 25 ms until the violation log's capacity of 200 was
      // full. Two whole 35-minute runs, twice each, reported that as the
      // headline failure of the phase's headline deliverable.
      test('is not a violation while the panel renders exactly what the plant '
          'is publishing', () {
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key])
          ..plantTruth[key] =
              const SoakPlantTruth(value: 680, overridden: true);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 680);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(seconds: 40);
        checker.sample(_at(const Duration(seconds: 40)));

        expect(checker.violations, isEmpty,
            reason: 'the plant is publishing 680 every poll cycle and the '
                'panel is rendering 680, so 680 IS the current state of the '
                'plant. There is no old number on the screen and no operator '
                'is being misled — which is the property, and the age of the '
                'last CHANGE is only ever a proxy for it');
      });

      test('is still judged when the panel renders something else', () {
        // The exclusion above must not become "pinned keys are not judged".
        // A panel still showing the pre-pin sweep counter while the plant has
        // moved on to 680 is exactly the failure invariant 1 is for, and it is
        // the failure a blanket exclusion would hide.
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key])
          ..plantTruth[key] =
              const SoakPlantTruth(value: 680, overridden: true);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 5123);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(seconds: 40);
        checker.sample(_at(const Duration(seconds: 40)));

        expect(checker.violations, hasLength(1),
            reason: 'the plant has been publishing 680 for forty seconds and '
                'this panel is rendering 5123 as CURRENT. Pinning a key must '
                'narrow the arithmetic, never retire the arm');
      });

      test('is still counted as a judged, fresh reading', () {
        // The rule refreshes the anchor; it does not retire the key. At seed 11
        // roughly ten of the twelve storm keys are pinned by the end of a
        // 35-minute run, so a rule that skipped the reading would stop judging
        // about a fifth of the surface while `judgedSamples` still claimed
        // otherwise — a vacuity gate cleared by readings nobody looked at.
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key])
          ..plantTruth[key] =
              const SoakPlantTruth(value: 680, overridden: true);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 680);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(seconds: 40);
        checker.sample(_at(const Duration(seconds: 40)));

        expect(checker.freshSamples, greaterThan(0));
        expect(checker.pinnedAnchorRefreshed, greaterThan(0),
            reason: 'the counter is how the verdict block says how often the '
                'arrival proxy could not answer and plant truth had to');
      });

      test('a key the plant sweeps is unaffected by the equality rule', () {
        // `overridden: false` is the sweep counter, which never repeats, so a
        // stale reading can never equal plant truth by accident. The rule is
        // gated on `overridden` anyway — the same distinction invariant 3
        // already draws ("overridden keys are judged on equality") — so that a
        // frozen PLANT cannot silence this checker across the board.
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key])
          ..plantTruth[key] = const SoakPlantTruth(
              value: 5123, overridden: false, sweepIndex: 5123);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 5123);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(seconds: 40);
        checker.sample(_at(const Duration(seconds: 40)));

        expect(checker.violations, hasLength(1),
            reason: 'equality with a swept key proves nothing: the counter is '
                'shared by every key on every link, so a panel frozen at the '
                'value the plant happens to be publishing is a coincidence '
                'and not evidence of an arrival');
      });
    });

    group('the per-episode latch', () {
      // **One episode is one finding, and 11-06 made this a prerequisite
      // rather than a nicety.** The violation printer truncates at 25 entries;
      // one freshness episode fanned out over four panels and re-counted every
      // 25 ms consumed all 25 slots on both 35-minute runs, which is why the
      // two surviving `boundedMemory` violations could not be identified at
      // all. Invariants 4 and 5 both latch already (`ratioReported`,
      // `overReported`); this was the one that did not.
      test('records one violation per panel and key, not one per tick', () {
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key]);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 7);
        checker.sample(_at(Duration.zero));
        for (var ms = 40000; ms <= 40200; ms += 25) {
          source.offset = Duration(milliseconds: ms);
          checker.sample(_at(Duration(milliseconds: ms)));
        }

        expect(checker.violations, hasLength(1),
            reason: 'nine consecutive ticks over the budget on one key of one '
                'panel is ONE breach observed nine times, and a log that '
                'records it nine times crowds out every other checker');
        expect(checker.repeatsSuppressed, greaterThan(0),
            reason: 'the suppressed repeats have to be counted, or the latch '
                'is a way of under-reporting rather than of grouping');
        expect(checker.freshnessEpisodes, 1);
      });

      test('a second episode after a recovery is recorded again', () {
        const key = 'ST101.CN01.MOT01.setpoint';
        final source = _Source(keys: <String>[key]);
        final checker = FreshnessHonestyChecker(source);

        source.panel(1).say(key, 7);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(seconds: 40);
        checker.sample(_at(const Duration(seconds: 40)));

        // A value arrives: the breach is over.
        source.panel(1).say(key, 8);
        source.offset = const Duration(seconds: 41);
        checker.sample(_at(const Duration(seconds: 41)));

        // And it goes over the budget a second time.
        source.offset = const Duration(seconds: 81);
        checker.sample(_at(const Duration(seconds: 81)));

        expect(checker.freshnessEpisodes, 2,
            reason: 'a latch that never released would report a pipe that '
                'breached, recovered and breached again as a single finding — '
                'which is the failure mode of latching, and the reason the '
                'release is asserted rather than assumed');
        expect(checker.violations, hasLength(2));
      });
    });

    test('a key with no value yet is not judged', () {
      final source = _Source();
      final checker = FreshnessHonestyChecker(source);
      checker.sample(_at(Duration.zero));

      expect(checker.judgedSamples, 0,
          reason: 'nothing has arrived for any key on any panel, so there is '
              'no reading to judge — and a checker that counted the call '
              'would clear its own vacuity gate while measuring nothing '
              '(11-01 sabotage 3)');
    });

    test('a key that has never arrived is not judged, and is not counted as '
        'stale', () {
      // Measured, not imagined: for the first ~100 ms of every composed run
      // each panel renders `Quality.uncertainNotYetKnown` with a null value for
      // every key — a placeholder node, before the first snapshot lands. The
      // gateway's own sweep makes exactly this distinction
      // (`freshness_sweep.dart`: "A key with no recorded arrival is skipped.
      // Nothing has ever come for it, so it is uncertainNotYetKnown and not
      // stale — those are different statements"), and a checker that counted
      // the placeholder as a stale reading would report 200 phantom stale
      // readings per panel per run, including on the control, where they read
      // as the strongest arm in the soak tripping on startup.
      final source = _Source();
      final checker = FreshnessHonestyChecker(source);
      source.panel(1).sayNothingYet('ST101.CN01.MOT01.setpoint');
      checker.sample(_at(Duration.zero));

      expect(checker.judgedSamples, 0);
      expect(checker.staleSamples, 0,
          reason: '"nothing has arrived" and "what arrived is old" are '
              'different statements, and only the second is a freshness '
              'verdict at all');
    });

    test('the counters partition: fresh plus stale is every judged reading',
        () {
      final source = _Source();
      final checker = FreshnessHonestyChecker(source);
      source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
      source.panel(2).say('ST201.CN01.MOT01.setpoint', 1);
      source.panel(2).viewIsStale = true;
      checker.sample(_at(Duration.zero));
      checker.sample(_at(const Duration(milliseconds: 25)));

      expect(checker.freshSamples + checker.staleSamples, checker.judgedSamples,
          reason: 'a reading is either one or the other, and a partition that '
              'does not add up is a counter nobody can read the verdict block '
              'against');
    });

    group('the PIPE. exclusion', () {
      test('skips a health key invented in this test, by prefix', () {
        // 08-05 task 3's `PIPE.invented.later` proof, restated: the skip has to
        // be `PipeKeys.isPipeKey`, so a health key nobody has thought of yet is
        // excluded on the day it is invented. An enumerated list would judge
        // this one and grey it out permanently while nothing is wrong
        // (06-SUMMARY on `PIPE.cert.days_to_expiry`).
        const invented = 'PIPE.invented.later';
        final source = _Source(keys: <String>[invented]);
        final checker = FreshnessHonestyChecker(source);
        source.panel(1).say(invented, true);
        checker.sample(_at(Duration.zero));
        source.offset = const Duration(minutes: 5);
        checker.sample(_at(const Duration(minutes: 5)));

        expect(checker.violations, isEmpty,
            reason: 'a value in the gateway\'s own namespace changes on an '
                'event and is older than any plant deadline by design');
        expect(checker.judgedSamples, 0,
            reason: 'skipped and NOT judged: counting a skipped key would let '
                'a run of nothing but health keys clear the vacuity gate');
      });

      test('and it does judge a plant key that merely mentions the prefix',
          () {
        const plantKey = 'ST101.CN01.PIPE01.setpoint';
        final source = _Source(keys: <String>[plantKey]);
        final checker = FreshnessHonestyChecker(source);
        source.panel(1).say(plantKey, 3);
        checker.sample(_at(Duration.zero));

        expect(checker.judgedSamples, greaterThan(0),
            reason: 'the prefix is "PIPE." with its dot, so a plant device '
                'called PIPE01 is a plant key and is judged like one');
      });
    });

    group('the run-end distribution', () {
      test('fails a run in which nothing ever went stale', () {
        final source = _Source();
        final checker = FreshnessHonestyChecker(source);
        source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(checker.violations, hasLength(1));
        expect(checker.violations.single.toString(), contains('staleSamples'),
            reason: 'a freshness verdict from a run where nothing ever went '
                'stale is a broken soak wearing a green tick, and the message '
                'has to say WHICH of the two numbers was zero');
      });

      test('fails a run in which nothing was ever fresh', () {
        final source = _Source();
        final checker = FreshnessHonestyChecker(source);
        source.panel(1)
          ..say('ST101.CN01.MOT01.setpoint', 1)
          ..viewIsStale = true;
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(checker.violations, hasLength(1));
        expect(checker.violations.single.toString(), contains('freshSamples'),
            reason: 'the panels never recovered, so the run measured a dead '
                'pipe rather than a storm');
      });

      test('passes a run that produced both', () {
        final source = _Source();
        final checker = FreshnessHonestyChecker(source);
        source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
        checker.sample(_at(Duration.zero));
        source.panel(1).viewIsStale = true;
        checker.sample(_at(const Duration(milliseconds: 25)));
        checker.finish();

        expect(checker.violations, isEmpty);
      });
    });

    group('the control panel\'s arm', () {
      test('a control that went stale with no plant-wide arm played is a '
          'violation', () {
        final source = _Source();
        final checker = FreshnessHonestyChecker(source);
        source.panel(0)
          ..say('ST101.CN01.MOT01.setpoint', 1)
          ..viewIsStale = true;
        source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
        checker.sample(_at(Duration.zero));
        checker.finish();

        final control = checker.violations
            .where((one) => one.toString().contains('control'))
            .toList();
        expect(control, hasLength(1),
            reason: 'the storm aimed at nothing plant-wide, so every fault it '
                'played was panel-targeted and the control was not one of the '
                'targets. A control that went stale anyway is the pre-07-08b '
                'bug class — a gateway punishing healthy panels');
      });

      test('and a plant-wide arm licenses it, because the control is not '
          'exempt from a gateway restart', () {
        final source = _Source()..plantWideArmsApplied = 1;
        final checker = FreshnessHonestyChecker(source);
        source.panel(0)
          ..say('ST101.CN01.MOT01.setpoint', 1)
          ..viewIsStale = true;
        source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(
            checker.violations
                .where((one) => one.toString().contains('control')),
            isEmpty,
            reason: 'GatewayRestart, KeymappingReload and every upstream arm '
                'reach the control like everybody else. The control\'s '
                'property is that the storm never AIMS at it, never that it '
                'is undisturbed — and an arm written against the second '
                'reading is flaky rather than strong');
      });

      test('a control stale for longer than its grace is a violation whatever '
          'the storm played', () {
        final source = _Source()..plantWideArmsApplied = 99;
        final checker = FreshnessHonestyChecker(source,
            controlStaleGrace: const Duration(seconds: 2));
        source.panel(0)
          ..say('ST101.CN01.MOT01.setpoint', 1)
          ..viewIsStale = true;
        source.panel(1).say('ST101.CN01.MOT01.setpoint', 1);
        for (var ms = 0; ms <= 4000; ms += 250) {
          checker.sample(_at(Duration(milliseconds: ms)));
        }
        checker.finish();

        expect(
            checker.violations
                .where((one) => one.toString().contains('never came back')),
            hasLength(1),
            reason: 'a plant-wide disturbance is transient. A control that '
                'never recovers is a finding no number of restarts excuses');
      });
    });

    test('the floor scales with the declared duration and never reaches zero',
        () {
      final short = FreshnessHonestyChecker(_Source(),
          declared: const Duration(seconds: 90), floorPerMinute: 4800);
      final full = FreshnessHonestyChecker(_Source(),
          declared: const Duration(minutes: 35), floorPerMinute: 4800);
      final tiny = FreshnessHonestyChecker(_Source(),
          declared: const Duration(milliseconds: 1), floorPerMinute: 4800);

      expect(short.minimumSamplesForAVerdict, 7200);
      expect(full.minimumSamplesForAVerdict, 168000);
      expect(tiny.minimumSamplesForAVerdict, greaterThanOrEqualTo(1),
          reason: 'a floor of zero is an assertion that cannot fail');
    });

    test('POSITIVE CONTROL: a blackholed panel forced to report fresh records '
        'exactly one violation, naming it', () async {
      // What this is a substitute FOR, and why the real thing is unavailable.
      //
      // 07-REVIEW CR-01's own defect is a freshness verdict aged on
      // `DateTime.now()` and then flipped by an NTP step. Neither half is
      // injectable here: `FreshnessWatchdog` takes a monotonic `int Function()`
      // and has no wall-clock seam left to hand in (07-REVIEW's note on
      // c4e62845 — "a seam that accepts a steppable clock is a seam somebody
      // steps"), and stepping the process clock is not something a CI job may
      // do. So the control holds a REAL panel behind a REAL blackholed proxy
      // until its REAL watchdog has judged the view stale, and then overrides
      // the one boolean a widget would render. Everything except the answer is
      // the shipping stack.
      //
      // A control that quietly tested something easier than the real defect
      // would be worse than none, so: this proves the checker catches a panel
      // whose verdict disagrees with its own arrival times. It does NOT prove
      // the checker would catch a client that aged its verdict on a wall clock
      // — nothing in this lane can, and 11-07's ledger says so.
      final driver = SoakDriver(
        seed: 11,
        duration: const Duration(seconds: 30),
        herdSize: 3,
        journalPath: _tempJournal(),
      );
      addTearDown(driver.dispose);
      await driver.start();

      const blackholed = 2;
      final honest = FreshnessHonestyChecker(driver);
      final lying = FreshnessHonestyChecker(
          _LyingSource(driver, liar: blackholed));
      // Both start sampling BEFORE the blackhole, so each has a record of when
      // the panel last genuinely heard about each key. A checker that first
      // looked after the link died would date every arrival to that moment and
      // find nothing old, which is the way this control fails silently.
      void sampleBoth() {
        for (final checker in <FreshnessHonestyChecker>[honest, lying]) {
          checker.sample(driver.clock);
        }
      }

      sampleBoth();
      driver.fixture.panels[blackholed].proxy.blackhole();
      // Past the client's 3 s link deadline, past the gateway's staleAfter, and
      // past the whole composed budget with room for a loaded runner.
      final until = driver.freshnessBudget + const Duration(seconds: 4);
      for (var waited = Duration.zero;
          waited < until;
          waited += const Duration(milliseconds: 250)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        sampleBoth();
      }

      expect(driver.panelViews[blackholed].viewIsStale, isTrue,
          reason: 'the control is worthless if the panel it lies about was '
              'never actually stale: the blackhole did not bite');

      expect(honest.violations, isEmpty,
          reason: 'the unmodified panel told the truth about being stale, so '
              'the checker must record nothing — otherwise the arm below is '
              'catching the blackhole rather than the lie');
      expect(lying.violations, isNotEmpty,
          reason: 'a panel reporting fresh over a value its own arrival times '
              'say is ${driver.freshnessBudget.inSeconds}s old is exactly the '
              'failure PROJECT.md names, and the checker did not see it');
      final first = lying.violations.first.toString();
      expect(first, contains(soakPanelName(blackholed)));
      expect(first, contains('seed=11'));
    });
  });

  group('the uploaded artifact', () {
    // **T-11-31, and two things the 35-minute arm proved were not true.**
    //
    // The soak's own failure reason ends: "The rest are in build/soak/, one
    // trip record each, with the twenty checkpoints before them and the
    // command that reproduces the run." Measured on the full arm: six
    // violations, and **not one trip record on disk** — `writeTrip` was
    // reachable only from `SoakDriver._record`, which is the population floor
    // and nothing else. Every violation this phase has ever recorded on a real
    // run came from a checker, so the forensics promised by the message have
    // never once been written.
    //
    // And `divergences.jsonl` is absent from a clean run entirely, because it
    // is only created when there is something to stream. An **empty** file is
    // evidence — the ledger ran and saw nothing; a **missing** one cannot be
    // told apart from a ledger that never ran, and the keyframe verdict rests
    // on that distinction.
    //
    // Asserted rather than eyeballed, because a missing file is exactly the
    // failure mode nobody notices while the run is green.
    test('carries every file a minute-23 trip needs to be diagnosable', () {
      final dir = _tempJournal();

      final journal = SoakJournal.open(seed: 4242, path: dir);
      journal.writeReproLog('soak seed=4242 duration=0:00:10.000000 entries=0');
      journal.writeConfig(<String, Object?>{'declaredDurationMs': 10000});
      journal.checkpoint(
        SoakClock.frozenAt(const Duration(seconds: 5),
            declaredDuration: const Duration(seconds: 10)),
        <String, Object?>{'checkpoint': 1},
      );
      journal.writeTrip(
        const SoakViolation(
          checker: freshnessHonesty,
          monotonic: Duration(seconds: 5),
          scheduleOffset: Duration(seconds: 5),
          detail: 'seed=4242 — a planted trip',
          observed: 1,
          expected: 0,
        ),
        armedModes: const <String>['blackhole'],
      );

      // The clean-run ledger: nothing recorded, and it still has to leave both
      // of its files behind.
      DivergenceLedger(_ResyncSource()..journalPath = dir).finish();

      final present = Directory(dir)
          .listSync()
          .map((entity) => entity.uri.pathSegments.last)
          .where((name) => name.isNotEmpty)
          .toSet();
      for (final required in <String>[
        'repro.log',
        'config.json',
        'metrics.jsonl',
        'events.jsonl',
        verdictFileName,
        divergenceFileName,
        'trip-0.txt',
      ]) {
        expect(present, contains(required),
            reason: 'the artifact is the whole of what a diagnosis has at '
                '07:00, and "$required" is not in it. Present: '
                '${present.toList()..sort()}');
      }
    });

    test('a checker violation writes a trip record, not only the driver\'s',
        () {
      // The narrow half of the case above, stated so the regression has a name
      // rather than being one entry in a file list.
      final dir = _tempJournal();
      final journal = SoakJournal.open(seed: 7, path: dir);
      journal.writeTrip(
        const SoakViolation(
          checker: boundedMemory,
          monotonic: Duration(minutes: 23),
          scheduleOffset: Duration(minutes: 23),
          detail: 'seed=7 — the minute-23 trip this artifact exists for',
        ),
        armedModes: const <String>[],
      );
      final record = File('$dir/trip-0.txt').readAsStringSync();
      expect(record, contains('minute-23 trip'));
      expect(record, contains('seed=7'),
          reason: 'a trip record has to be quotable into an issue without the '
              'run that produced it');
    });
  });

  group('the artifact carries no credential', () {
    // **T-11-30.** Phase 6 proved the credential appears in no message, no
    // close reason, no status frame and no log. The soak's journal is a
    // surface Phase 6 did not have: it is uploaded to a CI artifact, retained
    // seven days, and downloadable by anyone with repository access. Same
    // assertion, new surface.
    //
    // The fixture's tokens are `soak-panel-N-000000000000000`
    // (`SoakDriver._tokenForPanel`), which is deliberately shaped so nobody
    // mistakes it for a plant secret — and equally deliberately swept for, so
    // that the day a real credential reaches this code the sweep already
    // exists.
    test('and the sweep can find a planted one', () {
      // **The anti-vacuity control, and it comes first on purpose.** A sweep
      // that cannot find a needle proves nothing about a haystack, and this
      // phase has now produced four cases of a green result that meant less
      // than it looked like. Written before the real sweep runs so that a
      // broken sweep fails here rather than passing there.
      final dir = _tempJournal();
      File('$dir/repro.log').writeAsStringSync(
          'soak seed=11\n  panel-2 presented ${soakTokenForPanel(2)}\n');
      expect(_credentialHits(dir), isNotEmpty,
          reason: 'the sweep did not find a credential written into the '
              'directory by this very test, so a clean result from it would '
              'be a statement about the sweep and not about the artifact');
    });

    test('over the real artifact of the run that just happened', () {
      final dir = Directory(defaultSoakJournalDir);
      if (!dir.existsSync()) {
        // Guarded rather than failed: this file is run on its own in CI and by
        // anybody debugging one case, and a soak has not necessarily happened
        // in this working directory. The guard is `existsSync`, so the case
        // that matters — a directory that IS there — is never skipped.
        printOnFailure('no $defaultSoakJournalDir; nothing to sweep');
        return;
      }
      expect(_credentialHits(dir.path), isEmpty,
          reason: 'a token literal reached the forensics artifact, which is '
              'uploaded to CI and downloadable for seven days by anyone with '
              'repository access. The journal writes the storm, not the '
              'session — a credential in it means something is logging what '
              'it authenticated with');
    });
  });

  group('the plant-side applied-write ledger', () {
    test('the same key and value applied twice under two cmd ids appears '
        'twice', () {
      // The question the ledger exists to answer, and the one WriteOutcomeLog
      // structurally cannot: was this applied more than once? Two ids, because
      // one id twice is a different failure the client already refuses
      // (04-REVIEW CR-05).
      final ledger = AppliedWriteLedger();
      ledger.recordApplied(
          key: 'ST101.CN01.MOT01.setpoint', value: 1500, cmd: 'cmd-a');
      ledger.recordApplied(
          key: 'ST101.CN01.MOT01.setpoint', value: 1500, cmd: 'cmd-b');

      expect(ledger.appearances('ST101.CN01.MOT01.setpoint', 1500), 2);
      expect(ledger.appearances('ST101.CN01.MOT01.setpoint', 1400), 0,
          reason: 'the pair is the question; a different value is a '
              'different write');
    });

    test('nthWrite is run-stable and the cmd id is carried opaque', () {
      // Cmd ids are minted with Random.secure (ulid.dart:17-21), deliberately:
      // a predictable write id lets a hostile client re-query another
      // operator's outcome. So they differ between two runs of ONE seed, and
      // nothing reproducible may key on them.
      AppliedWriteLedger runWith(List<String> cmds) {
        final ledger = AppliedWriteLedger();
        for (final cmd in cmds) {
          ledger.recordApplied(key: 'ST201.CN02.MOT03.setpoint',
              value: cmds.indexOf(cmd), cmd: cmd);
        }
        return ledger;
      }

      final first = runWith(<String>['01JA', '01JB', '01JC']);
      final second = runWith(<String>['01ZZ', '01ZY', '01ZX']);

      expect(second.entries.map((one) => one.nthWrite),
          first.entries.map((one) => one.nthWrite),
          reason: 'two runs of one seed apply the same writes in the same '
              'order, so the n-th write is the identity that reproduces');
      expect(second.entries.map((one) => one.cmd),
          isNot(first.entries.map((one) => one.cmd)),
          reason: 'and the cmd ids are exactly what does not');
    });

    test('a panel attributed before the write lands is carried on the entry',
        () {
      final ledger = AppliedWriteLedger()..attribute('cmd-a', 'panel-3');
      ledger.recordApplied(
          key: 'ST301.CN01.MOT01.setpoint', value: 9, cmd: 'cmd-a');

      expect(ledger.entries.single.panel, 'panel-3',
          reason: 'the plant side does not know which panel acted; the driver '
              'does, and says so before the write crosses');
    });

    test('an unattributed application is recorded rather than dropped', () {
      final ledger = AppliedWriteLedger()
        ..recordApplied(key: 'ST301.CN01.MOT01.setpoint', value: 9,
            cmd: 'stranger');

      expect(ledger.entries.single.panel, isNull);
      expect(ledger.total, 1,
          reason: 'a write nobody attributed still reached the plant, and a '
              'ledger that dropped it would answer "applied once" about a '
              'key that moved twice');
    });

    test('DEVIATION 3\'s evidence: the entry outlives the gateway\'s own log',
        () {
      // The measurement the deviation rests on, taken rather than asserted.
      // WriteOutcomeLog prunes on every record AND every read
      // (tfc_relay_protocol/lib/src/write_outcome_log.dart:258-261,
      // removeWhere against now() - ttl — the class moved there in 18-04 and
      // this citation moved with it) against ServerConfig.writeOutcomeTtl,
      // default 60 s (server_config.dart:337). After thirty-five minutes it
      // holds at most the last minute, so "compared after the run" is a
      // comparison of the last sixty seconds wearing the label of the whole
      // soak.
      var wall = 1_700_000_000_000;
      final ttl = ServerConfig().writeOutcomeTtl;
      final gateway = WriteOutcomeLog(ttl: ttl, now: () => wall);
      final ledger = AppliedWriteLedger();

      gateway.record('cmd-a', const WriteApplied('cmd-a', readback: 1500, at: 0),
          fingerprint:
              (key: 'ST101.CN01.MOT01.setpoint', value: 1500, expect: null));
      ledger.recordApplied(
          key: 'ST101.CN01.MOT01.setpoint', value: 1500, cmd: 'cmd-a');

      expect(gateway.entryFor('cmd-a'), isNotNull,
          reason: 'inside the window the gateway does hold it, so the arm '
              'below is measuring the TTL and not a log that never recorded');

      wall += const Duration(seconds: 61).inMilliseconds;

      // Asked the way a post-run comparison would have to ask it. Note that
      // `recordedOutcomes` alone does NOT prune — it reads the raw map, and
      // only `record`, `entryFor` and `prune` sweep the horizon — so a reader
      // who took that counter as the log's contents would see an entry the
      // gateway will answer `null` about the moment anybody asks.
      final answer = gateway.entryFor('cmd-a');
      print('deviation 3, at +61 s: WriteOutcomeLog.entryFor(cmd-a)='
          '$answer, recordedOutcomes=${gateway.recordedOutcomes}, '
          'AppliedWriteLedger.total=${ledger.total} '
          '(ttl=$ttl)');

      expect(answer, isNull,
          reason: 'the gateway pruned it, which is correct behaviour and is '
              'exactly why §7.8\'s "compared after the run" cannot be done');
      expect(gateway.recordedOutcomes, 0,
          reason: 'and the sweep the question triggered dropped it from the '
              'map as well');
      expect(ledger.appearances('ST101.CN01.MOT01.setpoint', 1500), 1,
          reason: 'and the ledger still answers, which is what makes '
              '"applied twice?" a question minute 35 can ask about minute 3');
    });

    test('the cap bounds it and the overflow is counted', () {
      final ledger = AppliedWriteLedger(capacity: 10);
      for (var i = 0; i < 84; i++) {
        ledger.recordApplied(
            key: 'ST101.CN01.MOT01.setpoint', value: i, cmd: 'cmd-$i');
      }

      expect(ledger.entries, hasLength(10));
      expect(ledger.overflow, 74);
      expect(ledger.total, 84,
          reason: 'a capped list without a counter reports ten applications '
              'for a run that had eighty-four, which is a worse lie than the '
              'memory it saves');
      expect(ledger.entries.first.nthWrite, 1,
          reason: 'the FIRST applications are kept, as ViolationLog keeps the '
              'first violations: what a soak needs is when it started');
    });

    test('a truncated ledger says so rather than answering a question it can '
        'no longer answer', () {
      final ledger = AppliedWriteLedger(capacity: 1);
      expect(ledger.isTruncated, isFalse);
      ledger.recordApplied(key: 'k', value: 1, cmd: 'a');
      ledger.recordApplied(key: 'k', value: 2, cmd: 'b');

      expect(ledger.isTruncated, isTrue,
          reason: 'past the cap, appearances() is a FLOOR and not an answer, '
              'and a reconciliation that read it as an answer would report '
              '"applied once" about a write it had forgotten');
    });
  });

  group('invariant 2: one terminal state per write', () {
    test('POSITIVE CONTROL (a): a command resolved twice is a violation '
        'recorded at the instant it happened, carrying both states', () {
      final source = _WriteSource()
        ..issue('cmd-a', panel: 'panel-2', key: 'ST101.CN01.MOT01.setpoint',
            value: 7)
        ..resolve('cmd-a', 'applied', at: const Duration(seconds: 30))
        // The failure: the same operator action reaching a second terminal
        // state. One id is one action (04-REVIEW CR-05), so a second settled
        // answer means one of the two is being reported about the wrong write.
        ..resolve('cmd-a', 'rejected', at: const Duration(minutes: 4));
      final checker = TerminalStateChecker(source);
      checker.sample(_at(const Duration(minutes: 4)));

      expect(checker.violations, hasLength(1));
      final rendered = checker.violations.single.toString();
      for (final fragment in <String>[
        'applied',
        'rejected',
        '+04:00.000',
        '11',
      ]) {
        expect(rendered, contains(fragment),
            reason: 'the schedule offset at the instant is what makes a double '
                'resolution diagnosable — thirty minutes later the gateway\'s '
                'own log has forgotten. Missing "$fragment":\n$rendered');
      }
    });

    test('POSITIVE CONTROL (b): a write that reached a socket and is in '
        'neither map is a violation at run end', () {
      // PROJECT.md's named failure: a write silently lost. It is not in the
      // terminal map, so nothing ever settled it, and it is not in
      // debugUnresolvedCmds, so the client is not going to ask about it either.
      final source = _WriteSource()
        ..issue('cmd-lost', panel: 'panel-1', key: 'ST201.CN01.MOT01.setpoint',
            value: 3)
        ..direct('cmd-lost', 'unknown', reachedASocket: true);
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      final lost = checker.violations
          .where((one) => one.toString().contains('in NEITHER'))
          .toList();
      expect(lost, hasLength(1),
          reason: 'a write nobody is tracking and nobody settled is exactly '
              'the "never silently lost" half of the Core Value');
      expect(lost.single.toString(), contains('cmd-lost'));
    });

    test('a write a panel restart orphaned is accounted, not reported lost',
        () {
      // The instrument defect 11-08 found on the 35-minute arm, at unit scale.
      // The cmd is in neither the terminal map nor the LIVE unresolved set —
      // but it is in the set of a client `GateBFixture.redial` retired, and
      // that panel really was restarted, after the write.
      final source = _WriteSource()
        ..issue('cmd-orphan', panel: 'panel-2',
            key: 'ST301.CN01.MOT03.setpoint', value: 3)
        ..direct('cmd-orphan', 'unknown', reachedASocket: true)
        ..orphaned('cmd-orphan')
        ..restarted('panel-2', const Duration(seconds: 40));
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(
          checker.violations
              .where((one) => one.toString().contains('in NEITHER')),
          isEmpty,
          reason: 'the panel restarted; it did not lose the write. The command '
              'is still in the retired client\'s unresolved set, which is the '
              'harness remembering what the plant forgot');
      expect(checker.orphanedByRestart, 1,
          reason: 'and it is COUNTED rather than absorbed — a design '
              'consequence that appears as a number on every run is one that '
              'stays visible');
    });

    test('ANTI-WIDENING: an orphan-looking write whose panel never restarted, '
        'or that was issued after the restart, is still lost', () {
      // **The arm that stops "orphaned" becoming `_epochBumped`.** Membership
      // in the retired set is condition (1); a bucket that admits on
      // membership alone is exactly the shape that manufactured M-01's
      // "unattributed 0" by moving events out of the bucket the verdict
      // counted. Both writes below are in `orphanedCmds` and neither may be
      // excused: one belongs to a panel that was never restarted, the other
      // was issued after its panel's only restart.
      final source = _WriteSource()
        ..issue('cmd-no-restart', panel: 'panel-1',
            key: 'ST101.CN01.MOT01.setpoint', value: 1)
        ..direct('cmd-no-restart', 'unknown', reachedASocket: true)
        ..orphaned('cmd-no-restart')
        // A restart, but of somebody else.
        ..restarted('panel-2', const Duration(seconds: 10));
      source.scheduleOffset = const Duration(seconds: 30);
      source
        ..issue('cmd-after', panel: 'panel-2',
            key: 'ST301.CN01.MOT01.setpoint', value: 2)
        ..direct('cmd-after', 'unknown', reachedASocket: true)
        ..orphaned('cmd-after');

      final checker = TerminalStateChecker(source);
      checker.sample(_at(const Duration(seconds: 30)));
      checker.finish();

      final lost = checker.violations
          .where((one) => one.toString().contains('in NEITHER'))
          .map((one) => one.toString())
          .toList();
      expect(lost, hasLength(2),
          reason: 'neither write is attributable to a restart of its own panel '
              'after it was issued, so neither is an orphan and both are the '
              'failure the Core Value names. Got:\n${lost.join('\n')}');
      expect(lost.join('\n'), contains('cmd-no-restart'));
      expect(lost.join('\n'), contains('cmd-after'));
      expect(checker.orphanedByRestart, 0);
    });

    test('the orphan count is PRINTED, beside the restarts it is attributed '
        'to', () {
      // Three times this milestone a number has been correct, load-bearing and
      // printed nowhere — `unattributed` most recently, which is how ruling 5
      // came to be closed on a figure no reader ever saw. A number that is not
      // printed is not a standing measurement, so the verdict block's own
      // `toString` is pinned here.
      final source = _WriteSource()
        ..issue('cmd-orphan', panel: 'panel-2', key: 'k', value: 3)
        ..direct('cmd-orphan', 'unknown', reachedASocket: true)
        ..orphaned('cmd-orphan')
        ..restarted('panel-2', const Duration(seconds: 40));
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(checker.toString(), contains('1 orphaned by a panel restart'));
      expect(checker.toString(), contains('across 1 restarts'),
          reason: 'the denominator matters as much as the count: one orphan '
              'across one restart is a modelled consequence, and one across '
              'zero restarts would be a contradiction the reader must see');
    });

    test('the SAME terminal state re-reported through the recovery path is '
        'counted, not a violation', () {
      // Measured in the lane, in roughly half of ninety-second runs, always on
      // a probe write to the flapping panel. The sequence is the pipe working:
      //
      //   1. write() sends; the cmd is in `_unresolved` from before it left.
      //   2. the gateway records the outcome and answers.
      //   3. the link flaps; on the next entry to `ready` the client re-queries
      //      writeStatus for everything still unresolved, and the gateway
      //      answers from its own log — `_settle` fires `onWriteResolved`.
      //   4. the original write() future ALSO returns, with the same outcome.
      //
      // One operator action, ONE terminal state, reported through two channels
      // that agree. The invariant forbids a write reaching two terminal states,
      // not an outcome being reported twice — and treating agreement as a
      // breach would make the strongest arm in invariant 2 fire on a healthy
      // pipe about half the time. What stays a violation is DISAGREEMENT, and
      // the "never duplicated server-side" half is answered by the plant-side
      // ledger, which is a different arm entirely.
      final source = _WriteSource()
        ..issue('cmd-a', panel: 'panel-1', key: 'PIPE.connected', value: 1)
        ..resolve('cmd-a', 'rejected', at: const Duration(seconds: 34))
        ..direct('cmd-a', 'rejected', reachedASocket: true,
            at: const Duration(seconds: 34))
        ..settled('cmd-b', 'applied')
        ..issue('cmd-c', panel: 'panel-1', key: 'k', value: 1)
        ..direct('cmd-c', 'unknown', reachedASocket: true)
        ..stillUnresolved('cmd-c');
      final checker = TerminalStateChecker(source);
      checker.sample(_at(const Duration(seconds: 34)));
      checker.finish();

      expect(checker.violations, isEmpty);
      expect(checker.reResolvedInAgreement, 1,
          reason: 'counted rather than swallowed: a run where the recovery '
              'path re-reports half the writes is telling you something about '
              'the storm, and a number nobody prints is a number nobody reads');
    });

    test('a write that never reached a socket is NOT demanded to be terminal',
        () {
      // The client removes an undispatched cmd from `_unresolved` on purpose
      // (remote_state_man.dart:832-836): re-querying it every reconnect for the
      // rest of the shift is how a panel with a dead link grows the unresolved
      // set until writeStatus is refused for being over maxKeysPerSubscribe,
      // taking the recovery path for the GENUINE unknowns down with it. A
      // checker that demanded terminality here would be asserting against that
      // protection.
      final source = _WriteSource()
        ..issue('cmd-stillborn', panel: 'panel-4',
            key: 'ST301.CN01.MOT01.setpoint', value: 1)
        ..direct('cmd-stillborn', 'unknown', reachedASocket: false)
        // One healthy write so the distribution arms have something to pass on.
        ..issue('cmd-ok', panel: 'panel-1', key: 'ST101.CN01.MOT01.setpoint',
            value: 2)
        ..direct('cmd-ok', 'applied', reachedASocket: true)
        ..issue('cmd-no', panel: 'panel-1', key: 'PIPE.connected', value: 2)
        ..direct('cmd-no', 'rejected', reachedASocket: true);
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(
          checker.violations
              .where((one) => one.toString().contains('cmd-stillborn')),
          isEmpty);
      expect(checker.neverReachedASocket, 1,
          reason: 'counted rather than ignored: a run where every write died '
              'in the process is a run that measured nothing, and the number '
              'has to be readable next to judgedSamples');
    });

    test('a command in BOTH the terminal map and the unresolved set is a '
        'violation', () {
      final source = _WriteSource()
        ..issue('cmd-a', panel: 'panel-1', key: 'k', value: 1)
        ..direct('cmd-a', 'applied', reachedASocket: true)
        ..stillUnresolved('cmd-a');
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(
          checker.violations.where((one) => one.toString().contains('in BOTH')),
          hasLength(1),
          reason: 'a settled command the client is still going to re-query is '
              'one the operator will be told about twice, and the second '
              'answer may disagree with the first');
    });

    test('judgedSamples counts resolved writes and never sample calls', () {
      final source = _WriteSource()
        ..issue('cmd-a', panel: 'panel-1', key: 'k', value: 1)
        ..direct('cmd-a', 'applied', reachedASocket: true);
      final checker = TerminalStateChecker(source);
      for (var i = 0; i < 40; i++) {
        checker.sample(_at(Duration(milliseconds: 25 * i)));
      }

      expect(checker.judgedSamples, 1,
          reason: 'forty sample calls and one resolved write. 11-01\'s third '
              'sabotage: a counter that counted calls let a permanently broken '
              'checker clear the very gate built to catch it');
    });

    group('the run-end distribution', () {
      test('fails a run that produced no unknown', () {
        final source = _WriteSource()
          ..settled('cmd-a', 'applied')
          ..settled('cmd-b', 'rejected');
        final checker = TerminalStateChecker(source);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(
            checker.violations.where((one) => one.toString().contains('unknown')),
            hasLength(1),
            reason: 'a storm that produced no unknown never broke a link '
                'during a write\'s round trip, so the invariant\'s hard case '
                'was never tested at all');
      });

      test('fails a run that produced no rejected', () {
        final source = _WriteSource()
          ..settled('cmd-a', 'applied')
          ..issue('cmd-b', panel: 'panel-1', key: 'k', value: 1)
          ..direct('cmd-b', 'unknown', reachedASocket: true)
          ..stillUnresolved('cmd-b');
        final checker = TerminalStateChecker(source);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(
            checker.violations
                .where((one) => one.toString().contains('rejected')),
            hasLength(1));
      });

      test('is not asked of a run too short to have produced one', () {
        // Measured: `soak_test.dart`'s auxiliary cases declare eight and twelve
        // seconds to prove the seed reaches stdout and that two runs of one
        // seed play the same storm. Eight seconds is three probe writes, and an
        // `unknown` needs a link to break DURING a write's round trip — a
        // coincidence three writes cannot be relied on to produce. Asserting
        // the distribution there would make a smoke test of the machinery fail
        // for a property it was never running long enough to have.
        //
        // Invariant 1's distribution is deliberately NOT gated the same way,
        // and the asymmetry is real rather than an oversight: freshness is
        // sampled forty times a second from the first tick, so both a fresh and
        // a stale reading appear in any run of any length that has a fault in
        // it. Writes are two seconds apart.
        final source = _WriteSource()
          ..declaredDuration = const Duration(seconds: 8)
          ..settled('cmd-a', 'applied');
        final checker = TerminalStateChecker(source);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(checker.violations, isEmpty);
        expect(checker.distributionWasAsked, isFalse,
            reason: 'and the run has to SAY it was not asked, or a green '
                'eight-second run reads as a distribution that held');
      });

      test('is asked of any run at or past the floor', () {
        final source = _WriteSource()
          ..declaredDuration = distributionArmFloor
          ..settled('cmd-a', 'applied');
        final checker = TerminalStateChecker(source);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(checker.distributionWasAsked, isTrue);
        expect(checker.violations, hasLength(2),
            reason: 'no rejected and no unknown, each failing by name');
      });

      test('passes a run that produced all three', () {
        final source = _WriteSource()
          ..settled('cmd-a', 'applied')
          ..settled('cmd-b', 'rejected')
          ..issue('cmd-c', panel: 'panel-1', key: 'k', value: 1)
          ..direct('cmd-c', 'unknown', reachedASocket: true)
          ..stillUnresolved('cmd-c');
        final checker = TerminalStateChecker(source);
        checker.sample(_at(Duration.zero));
        checker.finish();

        expect(checker.violations, isEmpty);
        expect(checker.applied, 1);
        expect(checker.rejected, 1);
        expect(checker.unknown, 1);
      });
    });

    test('the plant applying one command twice is a violation', () {
      final source = _WriteSource()
        ..settled('cmd-a', 'applied')
        ..settled('cmd-b', 'rejected')
        ..issue('cmd-c', panel: 'panel-1', key: 'k', value: 1)
        ..direct('cmd-c', 'unknown', reachedASocket: true)
        ..stillUnresolved('cmd-c');
      // Two applications under one command id: the question the ledger exists
      // to answer and the gateway's sixty-second log cannot.
      source.appliedWrites
        ..attribute('cmd-a', 'panel-1')
        ..recordApplied(key: 'ST101.CN01.MOT01.setpoint', value: 5, cmd: 'cmd-a')
        ..recordApplied(key: 'ST101.CN01.MOT01.setpoint', value: 5, cmd: 'cmd-a');
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(
          checker.violations
              .where((one) => one.toString().contains('the plant applied')),
          hasLength(1));
    });

    test('a run-end violation is stamped with the WRITE\'s instant, not the '
        'run\'s end', () {
      // **The most diagnostic field in a trip record was describing the wrong
      // moment.** `writeTrip` prints `modes armed` by looking up
      // `violation.scheduleOffset` in the timeline, and the run-end arm
      // stamped every violation with `source.scheduleOffset` — the end of the
      // run. The 35-minute arm's `trip-0.txt` therefore read `monotonic:
      // +00:00.000 / schedule: +35:00.001 / modes armed: blackhole` for a
      // write issued at about +03:24, which a reader takes as "the panel was
      // blackholed when this happened". It is not what it says, and it is the
      // one field they would act on.
      //
      // The issued record is in hand at every call site, so this costs an
      // argument.
      final source = _WriteSource()
        ..settled('cmd-a', 'applied')
        ..settled('cmd-b', 'rejected');
      source.scheduleOffset = const Duration(minutes: 3, seconds: 24);
      source
        ..issue('cmd-lost',
            panel: 'panel-2', key: 'ST301.CN01.MOT03.setpoint', value: 5)
        ..direct('cmd-lost', 'unknown', reachedASocket: true);
      // The run ends half an hour later, and nothing settles the write.
      source.scheduleOffset = const Duration(minutes: 35);
      final checker = TerminalStateChecker(source);
      checker.sample(_at(const Duration(minutes: 35)));
      checker.finish();

      final lost = checker.violations
          .where((one) => one.toString().contains('NEITHER'))
          .toList();
      expect(lost, hasLength(1), reason: 'the write-loss arm, unchanged');
      expect(lost.single.scheduleOffset,
          const Duration(minutes: 3, seconds: 24),
          reason: 'the trip record looks up the armed fault modes at this '
              'offset. Stamped with the run\'s end it names whatever was armed '
              'at +35:00, which is a fault the write never saw');
      expect(lost.single.monotonic, const Duration(minutes: 3, seconds: 24));
    });

    test('the plant applying an UNKNOWN command twice is a violation', () {
      // **The one population where a duplicate application is plausible, and
      // the arm structurally excluded it.** `_consume` returns before
      // `_terminal[cmd] = ...` for `unknown` — correctly, because `unknown` is
      // not an established outcome — so a reconciliation that walked
      // `_terminal.keys` never asked the ledger about a command that stayed
      // unknown for the whole run.
      //
      // That is exactly the shape §7.8 and CLAUDE.md name: the link breaks
      // mid-round-trip, the client is told `unknown` and keeps the cmd
      // re-queryable, and the gateway or the upstream applies it a second time
      // across the reconnect. `_checkTheDistribution` REQUIRES `unknown > 0`,
      // so this population exists on every run — 2 to 5 per ninety-second lane
      // run, measured — and nothing was looking at it.
      //
      // The case above duplicates `cmd-a`, which is `applied`, which is why
      // the gap was invisible.
      final source = _WriteSource()
        ..settled('cmd-a', 'applied')
        ..settled('cmd-b', 'rejected')
        ..issue('cmd-c', panel: 'panel-4', key: 'BAADER.CN02.MOT03.setpoint',
            value: 9)
        ..direct('cmd-c', 'unknown', reachedASocket: true)
        ..stillUnresolved('cmd-c');
      source.appliedWrites
        ..attribute('cmd-c', 'panel-4')
        ..recordApplied(
            key: 'BAADER.CN02.MOT03.setpoint', value: 9, cmd: 'cmd-c')
        ..recordApplied(
            key: 'BAADER.CN02.MOT03.setpoint', value: 9, cmd: 'cmd-c');
      final checker = TerminalStateChecker(source);
      checker.sample(_at(Duration.zero));
      checker.finish();

      final duplicates = checker.violations
          .where((one) => one.toString().contains('the plant applied'))
          .toList();
      expect(duplicates, hasLength(1),
          reason: 'one button press moved the machine twice and the write was '
              'never established, so nothing else in this run will ever '
              'notice. An unknown that was applied twice is the worst case '
              'the three-state contract has: the operator is told "I cannot '
              'say", and the answer is "twice"');
      expect(duplicates.single.toString(), contains('panel-4'),
          reason: 'the violation is attributed from _issued, which holds the '
              'panel and key for every command the run made');
    });

    test('a truncated ledger is reported rather than read as an answer', () {
      final source = _WriteSource(ledgerCapacity: 1)
        ..settled('cmd-a', 'applied')
        ..settled('cmd-b', 'rejected')
        ..issue('cmd-c', panel: 'panel-1', key: 'k', value: 1)
        ..direct('cmd-c', 'unknown', reachedASocket: true)
        ..stillUnresolved('cmd-c');
      source.appliedWrites
        ..recordApplied(key: 'k', value: 1, cmd: 'cmd-a')
        ..recordApplied(key: 'k', value: 2, cmd: 'cmd-b');
      final checker = TerminalStateChecker(source);
      checker.finish();

      expect(
          checker.violations
              .where((one) => one.toString().contains('truncated')),
          hasLength(1),
          reason: 'past the cap appearances() is a floor, and a reconciliation '
              'that reported "no duplicates" off a floor would be answering a '
              'question it could no longer ask');
    });

    test('the unresolved set is bounded across the run, and the worst is '
        'recorded', () {
      final source = _WriteSource()
        ..settled('cmd-a', 'applied')
        ..settled('cmd-b', 'rejected');
      for (var i = 0; i < 9; i++) {
        source
          ..issue('cmd-p$i', panel: 'panel-1', key: 'k', value: i)
          ..direct('cmd-p$i', 'unknown', reachedASocket: true)
          ..stillUnresolved('cmd-p$i');
      }
      final checker = TerminalStateChecker(source, unresolvedCeiling: 4);
      checker.sample(_at(Duration.zero));
      checker.finish();

      expect(checker.worstUnresolved, 9);
      expect(
          checker.violations
              .where((one) => one.toString().contains('against a ceiling of')),
          hasLength(1),
          reason: 'the same counter invariant 4 watches as a slope (11-05 '
              'task 1). Here the question is whether it is bounded at all: an '
              'unresolved set that only grows is a writeStatus re-query that '
              'will eventually be refused for being over maxKeysPerSubscribe');
    });

    test('the floor scales with the declared duration', () {
      expect(
          TerminalStateChecker(_WriteSource(),
                  declared: const Duration(seconds: 90))
              .minimumSamplesForAVerdict,
          12);
      expect(
          TerminalStateChecker(_WriteSource(),
                  declared: const Duration(minutes: 35))
              .minimumSamplesForAVerdict,
          280);
    });
  });

  // ------------------------------------------------------------ invariant 4

  group('invariant 4: bounded memory', () {
    test('a structure that only ever grows is a violation naming it', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      // Nine readings, each one larger than the last. The first two are the
      // settle window; the rule needs `boundedMemoryMonotoneRun` strictly
      // increasing readings after that.
      for (var i = 0; i < 9; i++) {
        source.plantWide[sessionsStructure] = 5 + i;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, hasLength(1),
          reason: 'nine consecutive strictly increasing readings of '
              '$sessionsStructure went unrecorded — the monotone rule is what '
              'catches the leak that never spikes');
      final rendered = checker.violations.single.toString();
      for (final fragment in <String>[sessionsStructure, 'consecutive']) {
        expect(rendered, contains(fragment),
            reason: 'a slope violation that does not name the structure sends '
                'the reader to ten structures instead of one: $rendered');
      }
    });

    test('a structure that ends far above its own median is a violation', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      // A long flat stretch sets the median, then one reading far above it —
      // reached in a single step, so the monotone rule cannot be what fires.
      for (var i = 0; i < 10; i++) {
        source.plantWide[subscriptionsStructure] = 40;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      source.plantWide[subscriptionsStructure] = 40 * boundedMemoryRatio + 1;
      checker.sample(_at(const Duration(seconds: 55)));

      expect(checker.violations, hasLength(1),
          reason: 'a structure finished at more than K x its own median and '
              'nothing recorded it');
      expect(checker.violations.single.toString(), contains('median'),
          reason: 'the ratio rule must say what it compared against, or the '
              'number in the message cannot be checked');
    });

    test('the ratio rule says nothing below the pedestal', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      for (var i = 0; i < 10; i++) {
        source.plantWide[sessionsStructure] = 1;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      // Twenty times the median, and still a number no leak could hide in.
      source.plantWide[sessionsStructure] = 20;
      checker.sample(_at(const Duration(seconds: 55)));

      expect(checker.violations, isEmpty,
          reason: 'a median of one against a reading of twenty is a ratio of '
              'twenty and not a leak. Every structure here counts whole '
              'objects, so the small numbers are the ordinary ones and a rule '
              'that fires on them fires constantly');
    });

    test('a structure filling from zero is not judged before it settles', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      // Exactly the shape of a healthy start: nothing, then the herd arrives.
      for (final value in <int>[0, 2, 5, 5, 5, 5]) {
        source.plantWide[sessionsStructure] = value;
        checker.sample(_at(const Duration(seconds: 5)));
      }

      expect(checker.violations, isEmpty,
          reason: 'sessions climbing 0 -> 2 -> 5 at start() is the pipe coming '
              'up. A rule that judged the fill would fire on every healthy run, '
              'and a rule that has to be relaxed to be usable is the worst kind');
    });

    test('recordedOutcomes gets the longer settle the write-outcome TTL '
        'implies', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      // Twelve checkpoints of legitimate fill — one whole 60 s TTL at the 5 s
      // cadence — then the horizon starts pruning.
      for (var i = 0; i < 12; i++) {
        source.plantWide[recordedOutcomesStructure] = i + 1;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, isEmpty,
          reason: 'the outcome log accumulates every settled write until the '
              'oldest crosses ServerConfig.writeOutcomeTtl, so twelve '
              'checkpoints of monotone growth is the prune working rather than '
              'a leak. boundedMemorySettleOverrides carries the number and '
              'derives it from the gateway\'s own constant');
      expect(boundedMemorySettleOverrides[recordedOutcomesStructure], 13,
          reason: '60 s of TTL at a 5 s cadence is twelve checkpoints of fill '
              'plus the one the horizon is first crossed on');
    });

    test('and it needs the same allowance in the MIDDLE of a run, where the '
        'settle override cannot reach', () {
      // **The two surviving boundedMemory violations, identified.** 11-05b
      // dropped the count from 5 to 2 and could not say what the last two
      // were, because the violation printer's 25 slots were entirely consumed
      // by one freshness episode; 11-06 named the per-episode latch as the
      // prerequisite for reading them and, reasoning from the END-OF-RUN
      // spread (`worstRun=11` under the override of 13, `last` below
      // `median`), EXONERATED `recordedOutcomes`. With the latch in, the
      // 35-minute arm printed them: both are `recordedOutcomes`, at +18:10.003
      // and +18:35.050, each "after 5 consecutive increases from 28 (median)".
      //
      // The exoneration reasoned about a mid-run rule from end-of-run
      // statistics. `worstRun` is the longest climb ANYWHERE; the override it
      // was compared against governs only the run's first thirteen
      // checkpoints.
      //
      // And the derivation was already right — it just landed on the wrong
      // parameter. `boundedMemorySettleOverrides`' own comment argues that the
      // outcome log "accumulates every settled write until the oldest crosses
      // the horizon", which is twelve checkpoints of legitimate monotone
      // growth at the 5 s cadence. **That is a property of the structure, not
      // of the start of the run**: every time the write rate rises, the log
      // accumulates for a whole TTL before the horizon prunes again, at minute
      // 18 exactly as at minute 0. So the number belongs in
      // `boundedMemoryMonotoneOverrides` as well, for the same reason
      // `openSockets` is there — a translation of M into the units the series
      // is actually bounded in, not a loosening of it.
      //
      // The shape it is protecting is flat: 420 readings of
      // `recordedOutcomes: last=27 median=28 peak=32` across thirty-five
      // minutes. Nothing is leaking.
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      // Past the settle window first, on a structure at rest.
      for (var i = 0; i < 20; i++) {
        source.plantWide[recordedOutcomesStructure] = 28;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      // Then one whole TTL of accumulation, mid-run.
      for (var i = 20; i < 32; i++) {
        source.plantWide[recordedOutcomesStructure] = 28 + (i - 19);
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, isEmpty,
          reason: 'twelve checkpoints of fill is the prune working whenever it '
              'happens, and a rule that says so only for the first sixty '
              'seconds of a run reports the same healthy behaviour as a leak '
              'from minute two onwards');
      expect(boundedMemoryMonotoneOverrides[recordedOutcomesStructure], 13,
          reason: 'the same number as the settle override and from the same '
              'constant — ServerConfig.writeOutcomeTtl over the checkpoint '
              'cadence — because it is the same fact about the structure');
    });

    test('and thirteen consecutive increases still bites', () {
      // Or the override is an exemption wearing a number, which is the
      // objection `openSockets`' own case answers and this one has to answer
      // too. Past one whole TTL of accumulation the horizon must have started
      // pruning, so growth beyond it is growth the prune is not keeping up
      // with — which is the leak.
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);
      for (var i = 0; i < 20; i++) {
        source.plantWide[recordedOutcomesStructure] = 28;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      for (var i = 20; i < 40; i++) {
        source.plantWide[recordedOutcomesStructure] = 28 + (i - 19);
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.violations, isNotEmpty,
          reason: 'an outcome log that only ever grew for longer than its own '
              'TTL is a horizon that stopped pruning');
    });

    test('judgedSamples counts checkpoints with a non-zero structure, never '
        'checkpoints taken', () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);

      for (var i = 0; i < 4; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.judgedSamples, 0,
          reason: 'four checkpoints in which every structure read zero judged '
              'nothing: an _unresolved set empty for the whole run means no '
              'write was ever in flight during a fault. 11-01\'s third '
              'sabotage is this distinction — a counter counting CALLS let a '
              'checker that threw on every call clear the vacuity gate');
      expect(checker.checkpoints, 4);

      source.plantWide[sessionsStructure] = 5;
      checker.sample(_at(const Duration(seconds: 20)));
      expect(checker.judgedSamples, 1);
      expect(checker.checkpoints, 5);
    });

    test('every declared structure appears in the checkpoint row, by key set',
        () {
      final source = _StructureSource();
      final checker = BoundedMemoryChecker(source);
      source.plantWide[sessionsStructure] = 5;
      checker.sample(_at(Duration.zero));

      final watched = <String>{
        for (final key in checker.series.keys) key.split('/').last,
      };
      expect(watched, containsAll(boundedMemoryStructures),
          reason: 'a structure silently dropped from the reading is a '
              'structure nobody is watching, and it looks exactly like one '
              'that stayed flat. Missing: '
              '${boundedMemoryStructures.toSet().difference(watched)}');
      expect(boundedMemoryStructures.toSet(),
          boundedMemoryPanelStructures.toSet()
            ..addAll(boundedMemoryPlantWideStructures),
          reason: 'the two halves must add up to the whole list, or a '
              'structure can be declared and never read');
    });

    test('a platform that cannot read a structure skips it BY NAME', () {
      final source = _StructureSource()
        ..skips[openSocketsStructure] = 'no /proc/self/fd on this platform';
      final checker = BoundedMemoryChecker(source);
      source.plantWide.remove(openSocketsStructure);
      source.plantWide[sessionsStructure] = 5;
      checker.sample(_at(Duration.zero));

      expect(checker.skipped[openSocketsStructure], isNotEmpty,
          reason: 'a descriptor clause that quietly evaporates on one platform '
              'is exactly the failure gate_manifest_test.dart\'s skip audit '
              'exists to catch');
      expect(checker.toString(), contains(openSocketsStructure),
          reason: 'the skip has to print, or the run report shows a green '
              'invariant that judged one structure fewer than it says');
    });

    test('the control panel\'s structures are asserted flat before any '
        'plant-wide arm', () {
      final source = _StructureSource(panels: 3);
      final checker = BoundedMemoryChecker(source);

      // Held at a constant, deliberately: a CLIMBING control would also trip
      // the monotone rule, and then this case could not tell which arm caught
      // it. Six complaints that never move are invisible to both slope rules
      // and are exactly what the control arm is for.
      source.panel(0)[complaintsStructure] = 6;
      source.panel(1)[complaintsStructure] = 40;
      for (var i = 0; i < 6; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      final control = <SoakViolation>[
        for (final one in checker.violations)
          if (one.panel == 'panel-0') one,
      ];
      expect(control, isNotEmpty,
          reason: 'the control panel accumulated complaints while the storm '
              'had played NO plant-wide arm, so every fault in play was '
              'panel-targeted and the control is not a target. This is the '
              'pre-07-08b bug class: a gateway punishing healthy panels');
    });

    test('a plant-wide arm excuses the control, because the storm did not aim '
        'at it', () {
      final source = _StructureSource(panels: 3)..plantWideArmsApplied = 1;
      final checker = BoundedMemoryChecker(source);
      // The same six complaints as the case above, and the only difference is
      // that the storm has played one plant-wide arm.
      source.panel(0)[complaintsStructure] = 6;
      for (var i = 0; i < 6; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      expect(<SoakViolation>[
        for (final one in checker.violations)
          if (one.panel == 'panel-0') one,
      ], isEmpty,
          reason: 'GatewayRestart, KeymappingReload and every upstream arm '
              'reach the control like everybody else — 11-03\'s correction. An '
              'arm written against "it is never disturbed" would make the '
              'strongest instrument in the soak flaky rather than strong');
    });

    test('the violation names the structure, the panel, the offset and the '
        'seed', () {
      final source = _StructureSource(seed: 4242, panels: 3)
        ..offset = const Duration(minutes: 3, seconds: 20);
      final checker = BoundedMemoryChecker(source);
      for (var i = 0; i < 9; i++) {
        source.panel(2)[unresolvedCmdsStructure] = i;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      final rendered = checker.violations.first.toString();
      for (final fragment in <String>[
        'panel-2',
        unresolvedCmdsStructure,
        'seed=4242',
        '+03:20',
      ]) {
        expect(rendered, contains(fragment),
            reason: 'a trip record has to be quotable into an issue without '
                'the run that produced it: $rendered');
      }
    });

    test('the floor scales with the declared duration', () {
      expect(
          BoundedMemoryChecker(_StructureSource(),
                  declared: const Duration(seconds: 90))
              .minimumSamplesForAVerdict,
          9);
      expect(
          BoundedMemoryChecker(_StructureSource(),
                  declared: const Duration(minutes: 35))
              .minimumSamplesForAVerdict,
          210);
    });

    test('a checker past its violation cap reports the TOTAL, not the cap', () {
      // **"200" is a CEILING, not a count, and reading it as a count has cost
      // this phase real time twice** — two waves built diagnoses on it before
      // 11-07 found it was `violationLogCapacity` (`invariant.dart:171`). The
      // reason `ViolationLog` keeps an overflow counter at all is its own doc:
      // "a capped list without a counter would report '200 violations' for a
      // run that had eighty thousand, which is a worse lie than the memory it
      // saves". The counter existed; nothing above `ViolationLog` could read
      // it, because `InvariantChecker` exposes only `violations`.
      //
      // So `soak_test.dart`'s headline total summed `violations.length` — the
      // capped list — reintroducing the exact lie the counter prevents, in the
      // one message a person reads at 07:00.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      // The cap rule fires once per structure per breach episode, so break
      // several structures at once and keep them broken, cycling under and
      // back over so the latch re-arms. 300+ violations against a cap of 200.
      var i = 0;
      while (checker.violationTotal <= violationLogCapacity + 40) {
        source.panel(1)[writeStatusQueriesStructure] = i.isEven ? 70 : 10;
        checker.sample(_at(Duration(seconds: 5 * i)));
        i++;
        if (i > 2000) break; // never spin for ever on a broken checker
      }

      expect(checker.violations.length, violationLogCapacity,
          reason: 'the retained list is capped, which is correct and is the '
              'whole reason the counter has to be readable');
      expect(checker.violationTotal, greaterThan(violationLogCapacity),
          reason: 'and the total must be reachable from the INTERFACE — '
              'summing `violations.length` across the checkers is what turned '
              'eighty thousand into two hundred');
      expect(checker.violationOverflow,
          checker.violationTotal - violationLogCapacity);
      expect(checker.violationTotal,
          checker.violations.length + checker.violationOverflow,
          reason: 'retained + overflow = total, or the three numbers are not '
              'about the same run');
    });

    test('a CARRIED-FORWARD reading does not make a checkpoint judged', () {
      // **A path that increments the vacuity counter without judging
      // anything.** `anythingWasNonZero = true` was set before the
      // `carriedForward` `continue`, so a repeated `openSockets` value — the
      // one reading this checker explicitly refuses to feed to any rule, on
      // the grounds that it is not a reading — still advanced
      // `judgedSamples`. The file's own comment says the counter counts
      // "readings that said something".
      //
      // Inert today: `sessions` is 5 from the first checkpoint of any run
      // where the fixture came up, so the counter is dominated by structures
      // that are always non-zero. It is fixed because 11-01's third sabotage
      // is the standing lesson — a checker that THREW on all five calls
      // reported five readings against a floor of one and cleared the very
      // gate built to catch it — and a counter with a path that inflates it is
      // the same shape waiting for a run where the other structures are quiet.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      // Everything genuinely zero, and one structure carrying a stale
      // non-zero value forward.
      source.plantWide[openSocketsStructure] = 56;
      source.carriedForward.add(openSocketsStructure);
      for (var i = 0; i <= 4; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.checkpoints, 5);
      expect(checker.judgedSamples, 0,
          reason: 'every real structure read zero and the only non-zero number '
              'in the row is one the checker itself declined to judge. A '
              'checkpoint that judged nothing must not clear the vacuity gate '
              'on the strength of a value it refused to look at');
    });

    test('a source that throws becomes a recorded violation, never a dead run',
        () {
      final checker = BoundedMemoryChecker(_ThrowingStructureSource());
      checker.sample(_at(Duration.zero));

      expect(checker.violations, hasLength(1));
      expect(checker.violations.single.detail, contains('the checker itself threw'));
      expect(checker.judgedSamples, 0,
          reason: 'a checker that threw judged nothing, so its counter must '
              'not advance — 11-01\'s third sabotage in one assertion');
    });

    test('a structure filling toward its construction cap is not a leak', () {
      // Measured at thirty-five minutes, twice, identically:
      // `panel-1/writeStatusQueries: last=64 median=64 peak=64 worstRun=5`.
      // The list is RemoteStateMan._debugHistory, trimmed to 64 at
      // `remote_state_man.dart:1108`, and on a panel the storm rebuilt 234
      // times it fills slowly enough to cross M. Growth below a declared cap is
      // the container filling; the ninety-second lane never gets this ring past
      // single digits, which is why M=5 survived derivation.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      for (var i = 0; i <= 40; i++) {
        source.panel(1)[writeStatusQueriesStructure] =
            i < 64 ? i : 64; // climbs to the cap, then sits on it
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, isEmpty,
          reason: 'a ring filling to the size it is built to hold is the cap '
              'working, and a slope rule that calls it a leak is a rule that '
              'fires on every long run');
    });

    test('a structure ABOVE its construction cap is a violation naming the cap',
        () {
      // What is worth asking of a capped structure, and it is a stronger
      // question than any slope: the cap breaking means the code enforcing it
      // stopped running. That is the reason this structure was picked.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      for (var i = 0; i <= 6; i++) {
        source.panel(1)[writeStatusQueriesStructure] = i < 4 ? 64 : 70;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      // **A COUNT, not `isNotEmpty`.** The loop breaches on i=4, 5 and 6 — one
      // defect observed at three checkpoints — and an `isNotEmpty` here cannot
      // tell those apart. That mattered: unlatched, a structure stuck above
      // its cap records once per checkpoint per panel, which on the
      // thirty-five-minute arm is 420 checkpoints x up to 4 stormed panels,
      // about 1,600 violations for one defect. `ViolationLog` retains 200
      // (`invariant.dart:171`), so one finding fills the log and pushes every
      // other checker's FIRST occurrence into overflow — precisely what 11-06
      // measured on invariant 1 and named a prerequisite for reading anything
      // else in the log.
      expect(checker.violations, hasLength(1),
          reason: 'seventy entries in a list trimmed to sixty-four is ONE '
              'finding — the trim stopped running — however many checkpoints '
              'observe it. Three violations here is the missing latch, and '
              'the cap rule was the last bounded-memory rule without one '
              '(the ratio rule latches at :527, the monotone rule resets at '
              ':509, invariant 5 has overReported, invariant 1 got its '
              'episode latch in 11-07)');
      final first = checker.violations.first.toString();
      expect(first, contains(writeStatusQueriesStructure));
      expect(first, contains('64'));
      expect(first, contains('cap'));
      // Grouping, not under-reporting: the repeats the latch swallowed are
      // still counted, so a reader can tell one checkpoint from four hundred.
      expect(checker.capRepeatsSuppressed, 2,
          reason: 'i=5 and i=6 observed the same unbroken cap; a latch that '
              'dropped them without counting them would be the checker going '
              'quiet rather than grouping');
    });

    test('a capped structure that comes back under the cap and breaches again '
        'reports twice', () {
      // The other half of a latch, and the half that makes it a latch rather
      // than a mute. Two separate breaches with a healthy reading between them
      // are two findings; only an unbroken run is one.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      const readings = <int>[64, 64, 64, 64, 70, 70, 64, 64, 70, 70];
      for (var i = 0; i < readings.length; i++) {
        source.panel(1)[writeStatusQueriesStructure] = readings[i];
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, hasLength(2),
          reason: 'the trim came back and then stopped again — two episodes, '
              'and a latch that never cleared would report one');
      expect(checker.capRepeatsSuppressed, 2,
          reason: 'one suppressed repeat inside each of the two episodes');
    });

    test('the construction cap matches the product constant it duplicates', () {
      // The cap is RemoteStateMan._debugHistory. Duplicated here because the
      // checkers depend on soak_observables.dart and nothing else, and pinned
      // because a duplicated constant with nothing holding it to its original
      // is a checker that exempts at the wrong threshold the day somebody
      // raises the ring — silently, since no assertion reads the product's
      // number. Same idiom as the _resyncComplained pin in invariant 5.
      final client =
          File('../tfc_relay_client/lib/src/remote_state_man.dart');
      expect(client.existsSync(), isTrue,
          reason: 'the pin is worthless if the path rots: ${client.path}');
      expect(client.readAsStringSync(),
          contains('static const int _debugHistory = '
              '${boundedMemoryConstructionCaps[writeStatusQueriesStructure]}'),
          reason: 'boundedMemoryConstructionCaps and _debugHistory are the '
              'same number in two files, and this is the line that fails when '
              'they stop being');
    });

    test('openSockets needs a longer monotone run than the rest', () {
      // Measured at thirty-five minutes, twice, identically:
      // `plantWide/openSockets: last=30 median=42 peak=62 worstRun=5` — a count
      // that ENDS BOTH RUNS BELOW ITS OWN MEDIAN, which is the opposite of a
      // leak. It is read every openSocketCheckpointCadence checkpoints, so five
      // consecutive readings is two and a half minutes rather than
      // twenty-five seconds, and the descriptor count oscillates while the
      // storm opens and closes proxied sockets.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source);
      for (var i = 0; i <= 8; i++) {
        source.plantWide[openSocketsStructure] = 30 + i;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.violations, isEmpty,
          reason: 'five consecutive increases at this structure\'s cadence is '
              'ordinary storm churn, and both healthy thirty-five-minute arms '
              'reached exactly that');

      // Ten does have to bite, or the override is an exemption wearing a
      // number.
      for (var i = 9; i <= 14; i++) {
        source.plantWide[openSocketsStructure] = 30 + i;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.violations, isNotEmpty,
          reason: 'a descriptor count that only ever grew for ten readings is '
              'five minutes of a socket leak at this cadence, and no healthy '
              'arm has come near it');
      expect(checker.violations.first.toString(),
          contains(openSocketsStructure));
    });

    test('a carried-forward structure is a row entry and not a reading', () {
      // The descriptor count is read every sixth checkpoint because a
      // synchronous lsof stops the isolate for ~50 ms, and a soak about
      // behaviour under stress must not spend 1 % of itself inside its own
      // instrument. What must not follow is the repeat being fed to the rules:
      // five repeats in every six would break the monotone run of a structure
      // that is genuinely climbing, and the rule would look armed while being
      // unable to fire.
      final source = _StructureSource(panels: 2);
      final checker = BoundedMemoryChecker(source, monotoneRun: 3);
      for (var i = 0; i <= 20; i++) {
        source.plantWide[openSocketsStructure] = i; // climbing every checkpoint
        source.carriedForward
          ..clear()
          ..addAll(i % openSocketCheckpointCadence == 0
              ? const <String>[]
              : <String>[openSocketsStructure]);
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      final series = checker.series['plantWide/$openSocketsStructure'];
      expect(series, isNotNull);
      expect(series!.readings, 4,
          reason: 'twenty-one checkpoints at a cadence of '
              '$openSocketCheckpointCadence is four readings, not twenty-one');
      expect(series.worstMonotoneRun, 3,
          reason: 'and the four readings it did take were each larger than the '
              'last, so the slope is intact at a coarser resolution rather '
              'than destroyed by the repeats');
      expect(checker.carriedForward, contains(openSocketsStructure));
      expect(checker.spreadReport, contains('not every one'),
          reason: 'the coarser cadence prints, because a series with a '
              'quarter of the readings of its neighbours is something a '
              'reader has to be told rather than left to notice');
    });

    test('the POSITIVE CONTROL: a held unresolved command trips the monotone '
        'rule and names the structure', () {
      // The plan asked for a held `ResyncEngine._inFlight` entry. That map is
      // private and has no debug getter (`resync_engine.dart:235`), and
      // reaching it would mean editing tfc_relay_client/lib, which this plan
      // measures and does not change. The unresolved-write set is the same
      // shape of leak on the same client and is the structure
      // `long_outage_gate_test.dart` itself watches as a slope — and, unlike
      // `complaints`, it is NOT invariant 5's observable, so the control's
      // result is unambiguous about which rule fired and which checker fired
      // it.
      final source = _StructureSource(panels: 3);
      final checker = BoundedMemoryChecker(source);
      final held = _LeakingStructureSource(source,
          panel: 1, structure: unresolvedCmdsStructure);
      final leaking = BoundedMemoryChecker(held);

      for (var i = 0; i < 12; i++) {
        source.plantWide[sessionsStructure] = 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
        leaking.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, isEmpty,
          reason: 'the undecorated source is the negative half of the control: '
              'if it also trips, the control proves nothing about the leak');
      expect(leaking.violations, isNotEmpty,
          reason: 'a command held unresolved for ever is the leak this '
              'invariant exists to catch, and it must show as a SLOPE rather '
              'than against a ceiling');
      final first = leaking.violations.first.toString();
      expect(first, contains(unresolvedCmdsStructure));
      expect(first, contains('consecutive'),
          reason: 'the monotone rule and not the ratio rule: a held entry '
              'climbs by one a checkpoint and never spikes, so a maximum '
              'never sees it');
      expect(first, contains('+00:25'),
          reason: 'and WHEN it fires is the sabotage number worth pinning. '
              'Two settle checkpoints then five increases is the sixth '
              'reading, twenty-five seconds in. Replacing these rules with a '
              'maximum against a ceiling of 10 pushed the same control out to '
              '+00:50 and cost 22 violations on a HEALTHY ninety-second lane '
              'run (listeners at 250, recordedOutcomes at 28, openSockets at '
              '34, all against 10); against 64 — the cap 11-04 put on '
              'debugUnresolvedCmds, which is the number somebody reaching for '
              'a ceiling reaches for — it never fired at all, and could not '
              'have before checkpoint 65 at +05:20, which is four minutes past '
              'the end of the lane');
    });
  });

  // ------------------------------------------------------------ invariant 5

  group('invariant 5: bounded logs', () {
    test('a panel over the ceiling in one window is a violation naming the '
        'panel and the window', () {
      final source = _LogSource(panels: 3);
      final checker = BoundedLogsChecker(source, ceilingPerMinute: 30);

      // Thirty seconds of window, thirty complaints — sixty a minute against a
      // ceiling of thirty.
      for (var i = 0; i <= 6; i++) {
        source.panel(1).complaints = i * 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, isNotEmpty,
          reason: 'sixty complaints a minute against a ceiling of thirty went '
              'unrecorded');
      final rendered = checker.violations.first.toString();
      for (final fragment in <String>['panel-1', 'per minute']) {
        expect(rendered, contains(fragment), reason: rendered);
      }
    });

    test('a flood is still a flood when a redial resets the panel\'s counter',
        () {
      // **The reading this checker takes is off the LIVE client, and
      // `GateBFixture.redial` replaces it outright.** `_LivePanelLogView`
      // (`soak_driver.dart:2144`) is `_client.complaints.length`, and
      // `TokenRestore` calls `redial` (`:1889`), which disposes the old
      // `RemoteStateMan` and installs a new one. So `complaints` drops to 0
      // mid-run — while `reestablishments` does NOT, because `_health[i]` is
      // created once at `start()`. The anti-vacuity gate survives the reset
      // that destroys the quantity being judged, and that asymmetry is what
      // makes this a defect rather than noise.
      //
      // What it costs, concretely: a forty-complaint flood inside one minute,
      // then a redial before the next checkpoint. `last - oldest` goes
      // NEGATIVE, `rate` is negative, `rate <= ceilingPerMinute` holds,
      // `overReported` is cleared — and the window still counts toward
      // `judgedSamples`. The flood is erased and the verdict block reports a
      // green rate over a judged window.
      final source = _LogSource(panels: 3);
      final checker = BoundedLogsChecker(source, ceilingPerMinute: 30);

      // Sixty complaints across a full sixty-second window: 60/min against a
      // ceiling of 30. The window is exactly `boundedLogsRateWindow` wide by
      // the end, so the next reading slides it and the oldest retained count
      // is no longer zero — which is what makes the reset produce a NEGATIVE
      // rate rather than a merely flat one.
      for (var i = 0; i <= 12; i++) {
        source.panel(1).complaints = i * 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.violations, hasLength(1),
          reason: 'the flood itself, before any redial — this half is the '
              'control for the half below');

      // The redial: a new `RemoteStateMan`, a new empty complaint list.
      source.panel(1).complaints = 0;
      checker.sample(_at(const Duration(seconds: 65)));

      final panel = checker.windows[1]!;
      expect(panel.ratePerMinute, isNotNull);
      expect(panel.ratePerMinute! >= 0, isTrue,
          reason: 'the retained window still holds 5 complaints at its far '
              'end and the live client now reports 0, so `last - oldest` is '
              '-5 and the rate is NEGATIVE. That is not a rate — it is the '
              'instrument being replaced mid-measurement — and it is what '
              'clears overReported and launders the flood, while the window '
              'still counts toward judgedSamples');

      // And the panel goes on producing complaints from zero.
      for (var i = 14; i <= 18; i++) {
        source.panel(1).complaints = (i - 13) * 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(checker.violations, hasLength(1),
          reason: 'the flood is a fact about the run and a redial is not a '
              'retraction of it. Two violations would mean the post-redial '
              'climb was read as a fresh flood; ZERO would mean the reset '
              'erased the first');
      expect(panel.last, 85,
          reason: 'sixty complaints on the first incarnation and twenty-five '
              'on the second. The run total is the only number the backstop '
              'can be asked about — "a list growing steadily, slowly and for '
              'ever", the arm\'s stated purpose, cannot be seen across a '
              'redial if the run total is never held anywhere');
    });

    test('a panel under the ceiling is not a violation', () {
      final source = _LogSource(panels: 3);
      final checker = BoundedLogsChecker(source, ceilingPerMinute: 60);
      for (var i = 0; i <= 12; i++) {
        source.panel(1).complaints = i;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.violations, isEmpty,
          reason: 'twelve complaints a minute against a ceiling of sixty is a '
              'noisy storm and not a flood');
    });

    test('a window narrower than the minimum span is not judged', () {
      final source = _LogSource(panels: 3);
      final checker = BoundedLogsChecker(source, ceilingPerMinute: 1);
      source.panel(1).complaints = 0;
      checker.sample(_at(Duration.zero));
      source.panel(1).complaints = 100;
      checker.sample(_at(const Duration(seconds: 5)));

      expect(checker.violations, isEmpty,
          reason: 'a rate extrapolated from a five-second span multiplies '
              'whatever noise is in it by twelve');
      expect(checker.judgedSamples, 0,
          reason: 'and it must be SUBTRACTED from the judged count rather '
              'than silently passed, or a run of nothing but thin windows '
              'reads as a run that measured something');
    });

    test('a panel that never established is not judged', () {
      final source = _LogSource(panels: 3);
      for (final panel in source.panelLogs) {
        panel.established = false;
      }
      final checker = BoundedLogsChecker(source);
      for (var i = 0; i <= 12; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(checker.judgedSamples, 0,
          reason: 'a panel that never connected produced no complaints for a '
              'reason that is not this invariant\'s');
    });

    test('a run in which nobody ever rebuilt is a recorded violation', () {
      // The anti-vacuity arm, and it is a floor on REBUILDS. The RED asserted
      // `complaints > 0` here, on the plan's premise that no complaints means
      // no subscription was ever lost. Five lane runs refuted it: 5-8 rebuilds
      // and zero complaints, every run, because an ordinary flap that
      // resubscribes cleanly appends nothing. See `bounded_logs.dart`'s library
      // doc for the three append sites that make that so.
      final source = _LogSource(panels: 3);
      for (final panel in source.panelLogs) {
        panel.reestablishments = 0;
      }
      final checker = BoundedLogsChecker(source);
      for (var i = 0; i <= 12; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      expect(
          checker.violations.map((one) => one.detail).join('\n'),
          contains('never made a single panel rebuild'),
          reason: 'no rebuild means the complaint path was never reachable, so '
              'the ceiling held against a surface nothing exercised. For a flap '
              'storm it also means the faults reached nobody');
      expect(checker.surfaceWasExercised, isFalse);
    });

    test('zero complaints over a run that DID rebuild is not a violation', () {
      // The measured lane, exactly: the storm made panels rebuild and every
      // rebuild succeeded. This is the pipe working, and the first shape of
      // this arm would have failed the soak for it.
      final source = _LogSource(panels: 3);
      source.panel(1).reestablishments = 5;
      final checker = BoundedLogsChecker(source);
      for (var i = 0; i <= 12; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      expect(checker.totalComplaints, 0);
      expect(checker.violations, isEmpty,
          reason: 'five ninety-second lane runs produced exactly this shape — '
              '5-8 rebuilds across the herd and not one complaint — and a '
              'checker that calls it a broken soak is a checker that gets '
              'muted the week it lands');
      expect(checker.surfaceWasExercised, isTrue);
      expect(checker.toString(), contains('7 rebuilds'));
    });

    test('the control panel\'s complaint list stays near-empty', () {
      final source = _LogSource(panels: 3);
      // Declared at the RES-03 arm's length on purpose: the control's threshold
      // is an absolute total for the whole run while the backstop scales with
      // it, so on a one-minute run the backstop (10) is the stricter of the two
      // and would answer first. At thirty-five minutes the backstop is 350 and
      // this case is about the arm it says it is about.
      final checker = BoundedLogsChecker(source,
          declared: const Duration(minutes: 35), controlTotal: 12);
      source.panel(0).complaints = 40;
      source.panel(1).complaints = 3;
      for (var i = 0; i <= 12; i++) {
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      final control = <SoakViolation>[
        for (final one in checker.violations)
          if (one.panel == 'panel-0') one,
      ];
      expect(control, isNotEmpty,
          reason: 'forty complaints on the panel the storm may never aim at, '
              'against a threshold of twelve. This is the arm that would have '
              'caught the pre-07-08b heartbeat bug');
      expect(control.first.toString(), contains('12'));
    });

    test('the backstop catches slow steady growth the rate never sees', () {
      final source = _LogSource(panels: 3);
      final checker = BoundedLogsChecker(source,
          declared: const Duration(minutes: 1),
          ceilingPerMinute: 1000,
          totalBackstopPerMinute: 30);
      for (var i = 0; i <= 12; i++) {
        source.panel(1).complaints = i * 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      checker.finish();

      expect(
          checker.violations.map((one) => one.detail).join('\n'),
          contains('backstop'),
          reason: 'sixty complaints against a backstop of thirty, at a rate '
              'the ceiling of a thousand never notices — the one failure a '
              'rate cannot see');
    });

    test('the server-side line count is read and reported', () {
      final source = _LogSource(panels: 3)
        ..gatewayLogLines = 7
        ..plantIngestLogLines = 2;
      final checker = BoundedLogsChecker(source);
      checker.sample(_at(Duration.zero));

      expect(checker.gatewayLogLines, 7,
          reason: 'buildGateway\'s default error sink is log.e '
              '(gateway_config.dart:492-497), so one collected entry is one '
              'line the deployed gateway would write — the server half of '
              'this invariant needed no subprocess harness');
      expect(checker.plantIngestLogLines, 2);
      expect(checker.toString(), contains('gateway 7'));
    });

    test('the floor and the backstop both scale with the declared duration',
        () {
      expect(
          BoundedLogsChecker(_LogSource(),
                  declared: const Duration(seconds: 90))
              .minimumSamplesForAVerdict,
          15);
      expect(
          BoundedLogsChecker(_LogSource(), declared: const Duration(minutes: 35))
              .minimumSamplesForAVerdict,
          350);
      expect(
          BoundedLogsChecker(_LogSource(),
                  declared: const Duration(seconds: 90))
              .totalBackstop,
          15);
      expect(boundedLogsTotalBackstopPerMinute,
          lessThan(boundedLogsCeilingPerMinute),
          reason: 'the sustained allowance must sit BELOW the burst ceiling or '
              'it is unreachable: anything fast enough to breach a looser '
              'backstop breached the ceiling first, and the arm that is '
              'supposed to see slow steady growth would never fire');
    });

    test('the violation names the seed and the schedule offset', () {
      final source = _LogSource(seed: 4242, panels: 3)
        ..offset = const Duration(minutes: 3, seconds: 20);
      final checker = BoundedLogsChecker(source, ceilingPerMinute: 10);
      for (var i = 0; i <= 6; i++) {
        source.panel(1).complaints = i * 5;
        checker.sample(_at(Duration(seconds: 5 * i)));
      }
      final rendered = checker.violations.first.toString();
      expect(rendered, contains('seed=4242'));
      expect(rendered, contains('+03:20'));
    });

    test('the POSITIVE CONTROL: removing Phase 7\'s _resyncComplained '
        'damping trips the ceiling', () {
      // A live regression test on the damping, and it stays one after this
      // phase closes. The damping is `if (_resyncComplained.add(update.sub))`
      // in `connection_supervisor.dart` (line numbers deliberately not cited —
      // 16-07 moved them once already): once per subscription per
      // connection, so a page that keeps mismatching costs ONE complaint no
      // matter how many ticks it mismatches for. Removing the guard costs one
      // complaint per suppressed tick.
      //
      // The counterfactual is computed from the same run rather than by editing
      // the client, and it runs against the SHIPPING ceiling rather than a
      // tighter one passed in — which is the point of the derivation on
      // `boundedLogsCeilingPerMinute`. Twenty is half of the forty a minute the
      // undamped tick produces, so the number in the tree catches this without
      // help. The first draft of this file set the ceiling at sixty, which is
      // ABOVE the regression's own rate: the control passed only because the
      // case handed it a thirty.
      //
      // The arithmetic alone is not a regression test on the product — both
      // sources here are fakes — so the deletion is pinned structurally as
      // well, in the case below this one.
      const ticksPerMinute = 40; // a 1500 ms tick, the shipping default
      final damped = _LogSource(panels: 3);
      final undamped = _LogSource(panels: 3);
      final dampedChecker = BoundedLogsChecker(damped);
      final undampedChecker = BoundedLogsChecker(undamped);

      for (var i = 0; i <= 12; i++) {
        // Damped: one complaint for the whole mismatching stretch.
        damped.panel(1).complaints = 1;
        // Undamped: one per tick, which is what the guard is holding back.
        undamped.panel(1).complaints = (ticksPerMinute * 5 * i) ~/ 60;
        dampedChecker.sample(_at(Duration(seconds: 5 * i)));
        undampedChecker.sample(_at(Duration(seconds: 5 * i)));
      }

      expect(dampedChecker.violations, isEmpty,
          reason: 'with Phase 7\'s damping in place a permanently mismatching '
              'subscription costs one complaint per connection, which no '
              'ceiling should ever see');
      expect(undampedChecker.violations, isNotEmpty,
          reason: 'without it the same subscription costs one complaint per '
              'tick — $ticksPerMinute a minute against the shipping ceiling of '
              '$boundedLogsCeilingPerMinute. This arm is a live regression test '
              'on connection_supervisor.dart:771 and it keeps earning its keep '
              'after this phase closes');
      expect(undampedChecker.violations.first.toString(), contains('panel-1'));
      expect(ticksPerMinute, greaterThan(boundedLogsCeilingPerMinute * 2 - 1),
          reason: 'the ceiling must stay at or under half the rate the '
              'regression produces, or somebody raising it has quietly '
              'disarmed this control');
    });

    test('the POSITIVE CONTROL\'s other half: the damping itself is pinned',
        () {
      // The counterfactual above is arithmetic over two fakes; it proves the
      // ceiling would catch an undamped rate, and it cannot notice the guard
      // being deleted from the client. This half can, and it is the freeze
      // idiom this repository already uses for exactly that.
      final supervisor = File(
          '../tfc_relay_client/lib/src/connection_supervisor.dart');
      expect(supervisor.existsSync(), isTrue,
          reason: 'the pin is worthless if the path rots: ${supervisor.path}');
      final source = supervisor.readAsStringSync();

      expect(source, contains('_resyncComplained'),
          reason: 'Phase 7 added this suppression set for the G1 fix. Without '
              'it a permanently mismatching page complains once per 1500 ms '
              'tick — 40 a minute against invariant 5\'s ceiling of '
              '$boundedLogsCeilingPerMinute. Deleting it is the regression the '
              'soak\'s positive control describes, and this is the line that '
              'fails when somebody does. Renamed from _tickResyncComplained by '
              '16-07, which unified the three detectors behind ONE budget; the '
              'rename silently broke this pin because the file is soak-tagged '
              'and the default lane excludes it');
      expect(source, contains('if (_resyncComplained.add('),
          reason: 'the SET is not the damping — the guarded append is. A '
              'suppression set that is still declared, still cleared on '
              'reconnect and no longer consulted is the same flood with a '
              'reassuring name');
      expect(source, contains('bool _mayRebuild('),
          reason: '16-07 put all three resync detectors — tick mismatch, tick '
              'unestablished, and _update\'s unannounced-handle branch, which '
              'had NO rate limit at all — behind one shared rebuild budget. '
              'The complaint damping above bounds the LOG; this bounds the '
              'REBUILDS, and a 60-frame storm costs 5 instead of 60. Losing it '
              'would not trip invariant 5, so nothing else here would notice');
      expect(source, contains('_resyncComplained.clear()'),
          reason: 'and the clear on reconnect stays, deliberately: a recovered '
              'page must not be refused the rebuild it needs '
              '(11-05\'s objective quotes the reasoning). This invariant exists '
              'because that clearing is what makes a flood possible, not '
              'because the clearing is wrong');
    });
  });

  // ------------------------------------------------ the shared observable

  group('invariants 4 and 5 share an observable', () {
    test('two instruments recording against complaints in one checkpoint print '
        'as ONE FINDING, not as two', () {
      // Both checkers driven, at the same offsets, on the same list — which is
      // what a genuine flood does. Invariant 4 sees a structure that only ever
      // grows; invariant 5 sees a rate over its ceiling. They are right and
      // they are the same finding.
      final structures = _StructureSource(panels: 3);
      final logs = _LogSource(panels: 3);
      final memory = BoundedMemoryChecker(structures);
      final rate = BoundedLogsChecker(logs, ceilingPerMinute: 30);

      for (var i = 0; i <= 8; i++) {
        final at = Duration(seconds: 5 * i);
        structures.panel(1)[complaintsStructure] = i * 5;
        logs.panel(1).complaints = i * 5;
        memory.sample(_at(at));
        rate.sample(_at(at));
      }

      expect(memory.violations, isNotEmpty,
          reason: 'invariant 4 must have seen the growth, or this case is '
              'testing the cross-reference against one instrument');
      expect(rate.violations, isNotEmpty,
          reason: 'invariant 5 must have seen the rate, likewise');

      final sentence = sharedObservableFindings(<InvariantChecker>[memory, rate]);
      expect(sentence, isNotNull,
          reason: 'both instruments recorded against "$sharedObservable" and '
              'the block said nothing about it. Pitfall 8 is a report in which '
              'the two appear to corroborate each other');
      expect(sentence, contains('ONE FINDING SEEN BY TWO INSTRUMENTS'));
      expect(sentence, contains(boundedLogs));
      expect(sentence, contains(boundedMemory));
    });

    test('one instrument alone says nothing about a shared observable', () {
      final logs = _LogSource(panels: 3);
      final rate = BoundedLogsChecker(logs, ceilingPerMinute: 30);
      for (var i = 0; i <= 8; i++) {
        logs.panel(1).complaints = i * 5;
        rate.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(rate.violations, isNotEmpty);
      expect(sharedObservableFindings(<InvariantChecker>[rate]), isNull,
          reason: 'there is nothing to disclaim when only one instrument '
              'recorded, and a sentence printed anyway would be noise that '
              'trains everybody to skip the line that matters');
    });

    test('violations on other structures are not cross-referenced', () {
      final structures = _StructureSource(panels: 3);
      final logs = _LogSource(panels: 3);
      final memory = BoundedMemoryChecker(structures);
      final rate = BoundedLogsChecker(logs, ceilingPerMinute: 30);
      for (var i = 0; i <= 8; i++) {
        // Invariant 4 climbs on the unresolved set; invariant 5 on complaints.
        structures.panel(1)[unresolvedCmdsStructure] = i;
        logs.panel(1).complaints = i * 5;
        memory.sample(_at(Duration(seconds: 5 * i)));
        rate.sample(_at(Duration(seconds: 5 * i)));
      }
      expect(memory.violations, isNotEmpty);
      expect(rate.violations, isNotEmpty);
      expect(sharedObservableFindings(<InvariantChecker>[memory, rate]), isNull,
          reason: 'two findings on two different structures ARE two findings. '
              'The cross-reference must key on the observable and not on the '
              'fact that both checkers went red');
    });
  });

  group('invariant 5 is honest about arms too short to measure', () {
    test('a run shorter than one window exempts the floor and says so', () {
      final short = BoundedLogsChecker(_LogSource(),
          declared: const Duration(seconds: 8));
      expect(short.measurable, isFalse);
      expect(short.minimumSamplesForAVerdict, 0,
          reason: 'an eight-second run takes ONE checkpoint and a rate needs '
              'two readings, so a floor of one is not an anti-vacuity gate — '
              'it is a case that fails for the length of the arm');
      expect(short.toString(), contains('NOT MEASURABLE'),
          reason: 'and the exemption must print, or a green row means '
              'something it does not');
    });

    test('both real arms are far above the measurable floor', () {
      for (final arm in <Duration>[
        Duration(seconds: 90),
        Duration(minutes: 35),
      ]) {
        final checker = BoundedLogsChecker(_LogSource(), declared: arm);
        expect(checker.measurable, isTrue, reason: '$arm');
        expect(checker.minimumSamplesForAVerdict, greaterThan(0), reason: '$arm');
      }
    });

    test('an eight-second run is exempt from the rebuild floor too', () {
      final source = _LogSource(panels: 3);
      for (final panel in source.panelLogs) {
        panel.reestablishments = 0;
      }
      final short =
          BoundedLogsChecker(source, declared: const Duration(seconds: 8));
      short.sample(_at(Duration.zero));
      short.finish();
      expect(short.surfaceWasExercised, isTrue,
          reason: 'an eight-second auxiliary run may legitimately flap nobody, '
              'and the same argument that exempts the sample floor exempts '
              'this one — the exemption prints as NOT MEASURABLE either way');
      expect(short.violations, isEmpty);
    });
  });

  // -------------------------------------------------- the doctrine, swept

  group('the memory doctrine is enforced structurally', () {
    test('no line in the soak tree asserts on ProcessInfo.currentRss', () {
      final hits = _sweepSoakTreeFor(_rssNeedle);

      // The needle is real: the sweep must be able to find something, or a
      // typo in the pattern would make this case pass on an empty result.
      expect(hits, isNotEmpty,
          reason: 'the sweep found no occurrence of $_rssNeedle anywhere, '
              'which means it is looking in the wrong place rather than that '
              'the doctrine is held');

      final code = <String>[
        for (final hit in hits)
          if (_readsIt(hit.text)) '${hit.file}:${hit.line}: ${hit.text.trim()}',
      ];
      expect(code, hasLength(1),
          reason: 'RSS may appear in exactly one line of code in the whole '
              'soak tree — the journal write — and in doc comments otherwise. '
              'What was found instead:\n${code.join('\n')}');
      expect(code.single, contains('soak_driver.dart'));
      expect(code.single, contains("'rss'"),
          reason: 'the one permitted occurrence is a WRITE into the checkpoint '
              'map, and nothing else: ${code.single}');

      final asserted = <String>[
        for (final hit in hits)
          if (hit.text.contains('expect(')) '${hit.file}:${hit.line}',
      ];
      expect(asserted, isEmpty,
          reason: 'an expect() on the same line as $_rssNeedle is the ceiling '
              'long_outage_gate_test.dart:71-83 refuses, arriving by the back '
              'door: $asserted');
      expect(_expectNear(hits), isEmpty,
          reason: 'an expect() within three lines of $_rssNeedle is the same '
              'ceiling with a line break in it: ${_expectNear(hits)}');
    });

    test('the deviation that authorises this is declared and quotes the '
        'clause', () {
      final entry = soakDeviations.firstWhere(
          (one) => one.id.contains('invariant 4'),
          orElse: () => throw StateError('no deviation declares invariant 4\'s '
              'departure from §7.8, so the checker below is an undeclared '
              'one'));
      expect(entry.clause, contains('heap high-water marks bounded'),
          reason: 'paraphrase it and nobody can check the deviation against '
              'the catalogue, which is the only thing the entry is for');
      expect(entry.instead, contains('currentRss'));
      expect(entry.reasoning, contains('long_outage_gate_test.dart:71-83'));
    });
  });

  group('invariant 3: eventual resync in the windows the timeline generated',
      () {
    test('a panel holding the sweep the plant last wrote is converged, and one '
        'sweep behind still is', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 100);
      source.panel(2).say(_resyncKey, 99);

      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));

      expect(checker.ledger.total, 0,
          reason: 'the plant moves every key every 250 ms and the pipe is '
              'asynchronous, so a sample taken between a sweep and its '
              'delivery legitimately sees the previous value. Demanding '
              'instantaneous equality would report the wire\'s own transit '
              'time as a divergence — two hundred of them per sample on a '
              'healthy pipe, which is the flood convergedLagSweeps exists to '
              'prevent');
    });

    test('two sweeps behind AT THE WINDOW\'S END is a divergence, and it is '
        'handed to the ledger with a cause rather than counted', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 97);

      _judgeWindow(checker, source);
      checker.finish();

      expect(checker.ledger.total, 1);
      final event = checker.ledger.entries.single;
      expect(event.key, _resyncKey);
      expect(event.panelId, 'panel-1');
      expect(event.clientValue, 97,
          reason: 'the record carries what the JUDGEMENT INSTANT saw. A healed '
              'divergence whose record showed the healed values would say the '
              'panel and the plant agreed, which is the one thing it did not '
              'do — and the first lane run recorded exactly that before this '
              'arm existed');
      expect(event.plantValue, 100);
      expect(event.windowIndex, 0,
          reason: 'the window it was judged in is on the record, because a '
              'divergence inside a window the timeline guaranteed was quiet '
              'means something different from one outside it');
    });

    test('a key that is behind at a window\'s START and catches up before its '
        'END is MEASURED, not recorded', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 60);

      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));
      source.panel(1).say(_resyncKey, 100);
      source.scheduleOffset = source.insideWindow(0, plus: const Duration(seconds: 3));
      checker.takeReading(
          _at(source.insideWindow(0, plus: const Duration(seconds: 3))));
      source.scheduleOffset = source.afterWindow(0);
      checker.takeReading(_at(source.afterWindow(0)));
      checker.finish();

      expect(checker.ledger.total, 0,
          reason: 'a panel still catching up from a fault armed BEFORE the '
              'window is the pipe recovering, and the window exists to give it '
              'room. Counting it would make this artifact a record of the '
              'storm rather than of what survived it — the first lane run '
              'produced 124 such events, 119 of them mis-attributed');
      expect(checker.convergenceReport, contains('in-window convergence (ms)'));
      expect(checker.convergenceReport, contains('n=1'),
          reason: 'it is not an event, but it IS the measurement '
              'minStableWindow is judged against, so it has to be counted '
              'somewhere');
      expect(checker.marginNote, contains('window margin'));
    });

    test('the right value under the wrong quality is a divergence — this is '
        'the arm that keeps the epoch path visible', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).sayWithQuality(_resyncKey, 100, Quality.badStale);

      _judgeWindow(checker, source);
      checker.finish();

      expect(checker.ledger.total, 1,
          reason: 'a panel rendering the right number under a quality the '
              'plant never sent has stopped vouching for it, and comparing '
              'value alone would report the entire epochChange cause as '
              'convergence');
      expect(checker.ledger.entries.single.clientQuality, Quality.badStale);
      expect(checker.ledger.entries.single.plantQuality, Quality.good);
    });

    test('the checker does not become the leak it is measuring', () {
      // **Invariant 3 was the one sibling that retained per-READING.**
      // `bounded_memory.dart` keeps a frequency map for exactly this reason —
      // "the checker must not become the leak it is measuring", 07-RESEARCH
      // trap 15 — and `BoundedLogsWindow` ages its readings out past the
      // window. `_lagInWindow.add(lag)` ran once per key comparison inside a
      // window, and the thirty-five-minute arm does 127,440 of them, so the
      // list ended the run at roughly 128,000 entries and `convergenceReport`
      // sorted a COPY of it. It grows linearly in the parameter:
      // RELAY_SOAK_MINUTES=480 is about 1.7 million.
      //
      // What is asserted is the shape of the retention rather than a byte
      // count: readings scale with the run, retained values scale with the
      // RANGE of the quantity, and a lag in sweeps has a tiny range.
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 100);
      for (var i = 0; i < 400; i++) {
        // The source's own offset is what picks the window; the clock only
        // stamps the reading.
        final at = source.insideWindow(0,
            plus: Duration(milliseconds: 10 * (i % 500)));
        source.scheduleOffset = at;
        checker.takeReading(_at(at));
      }

      expect(checker.keysCompared, greaterThanOrEqualTo(400),
          reason: 'the readings really were taken — an arm that retained '
              'nothing because it compared nothing would pass this vacuously');
      expect(checker.retainedSamples, lessThan(64),
          reason: 'four hundred sweeps over a plant sitting still produce a '
              'handful of DISTINCT lag values and nothing else. Retaining one '
              'entry per comparison is what made a bounded-memory checker the '
              'unbounded structure in the room');
      // And the report must still say the same things about the same data.
      expect(checker.convergenceReport, contains('lag while judging (sweeps)'));
      expect(checker.convergenceReport, contains('n='));
    });

    test('PIPE. keys are excluded by prefix, because the gateway produces them '
        'and the plant does not', () {
      final source = _ResyncSource(keys: <String>[_resyncKey, 'PIPE.connected']);
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 100);
      source.panel(1).say('PIPE.connected', false);

      _judgeWindow(checker, source);
      checker.finish();

      expect(checker.ledger.total, 0,
          reason: 'there is no plant truth for a health key, so comparing one '
              'would be comparing against nothing');
    });

    test('a divergence that heals after its window carries healedWithinMs; one '
        'that never heals carries null', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 60);
      source.panel(2).say(_resyncKey, 60);

      _judgeWindow(checker, source);
      // panel-1 catches up two seconds past the window's end; panel-2 never
      // does.
      source.panel(1).say(_resyncKey, 100);
      source.scheduleOffset =
          source.afterWindow(0) + const Duration(seconds: 2);
      checker.takeReading(
          _at(source.afterWindow(0) + const Duration(seconds: 2)));
      checker.finish();

      final byPanel = <String, DivergenceEvent>{
        for (final one in checker.ledger.entries) one.panelId: one,
      };
      expect(byPanel['panel-1']!.healedWithinMs, 2000,
          reason: 'measured from the window\'s end, which is the instant the '
              'invariant is about');
      expect(byPanel['panel-1']!.isResidue, isFalse);
      expect(byPanel['panel-2']!.healedWithinMs, isNull,
          reason: 'null is the residue discriminator: it survived the interval '
              'in which the timeline guaranteed nothing was armed, and then '
              'survived everything after it');
      expect(byPanel['panel-2']!.isResidue, isTrue);
      expect(checker.ledger.residue, 1);
      expect(checker.ledger.healed, 1);
    });

    test('a window that compared nothing is not a window, and says so', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      // No panel holds a value: every read answers null, so nothing is
      // comparable.
      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));
      source.scheduleOffset = source.afterWindow(0);
      checker.takeReading(_at(source.afterWindow(0)));

      expect(checker.judgedSamples, 0,
          reason: 'judgedSamples counts WINDOWS MEASURED, and a window in '
              'which every panel was down measured nothing');
      expect(checker.violations, hasLength(1));
      expect(checker.violations.single.detail, contains('compared ZERO keys'));
    });

    test('a run with no stable windows fails loudly, naming the number found '
        'and the number required', () {
      final source = _ResyncSource(windows: const <StableWindow>[]);
      final checker = _resync(source);
      checker.finish();

      expect(checker.judgedSamples, 0);
      expect(checker.violations, hasLength(1));
      final detail = checker.violations.single.detail;
      expect(detail, contains('ZERO stable windows'));
      expect(detail, contains('against a floor of'));
      expect(detail, contains('TIMELINE problem'),
          reason: 'the fix is the quiet-window cadence in soak_timeline.dart, '
              'and a checker that failed without saying so would send the '
              'reader to the wrong file');
      expect(checker.violations.single.observed, 0);
      expect(checker.violations.single.expected,
          checker.minimumSamplesForAVerdict);
    });

    test('the window floor is one fewer than the timeline generates, at both '
        'durations', () {
      final lane = _ResyncSource()..declaredDuration = const Duration(seconds: 90);
      final full = _ResyncSource()..declaredDuration = const Duration(minutes: 35);

      expect(computeStableWindows(const Duration(seconds: 90)), hasLength(3),
          reason: 'the quiet-fraction cap binds at ninety seconds: three '
              'windows of ten. If this number moved, 11-02\'s generator '
              'changed and the floor below moved with it');
      expect(computeStableWindows(const Duration(minutes: 35)), hasLength(8),
          reason: 'the cadence term binds at thirty-five minutes: eight '
              'windows of twenty');
      expect(_resync(lane).minimumSamplesForAVerdict, 2);
      expect(_resync(full).minimumSamplesForAVerdict, 7,
          reason: 'one window of slack, because the storm is entitled to take '
              'panels down and 11-05 measured a run in which panel-1 was '
              'absent for the last fifteen minutes');
    });

    test('the never-faulted control panel diverging in an UNDISTURBED window '
        'is a violation', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(0).say(_resyncKey, 80);

      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));
      source.scheduleOffset = source.afterWindow(0);
      checker.takeReading(_at(source.afterWindow(0)));
      checker.finish();

      expect(checker.violations, hasLength(1));
      expect(checker.violations.single.panel, 'panel-0');
      expect(checker.violations.single.detail, contains('pre-07-08b'));
    });

    test('the control panel is NOT judged across a window the storm disturbed '
        'plant-wide', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(0).say(_resyncKey, 80);

      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));
      // A gateway restart, a keymapping reload or an upstream arm — plant-wide,
      // and it reaches the control like everybody else.
      source.plantWideArmsApplied = 1;
      source.scheduleOffset = source.insideWindow(0, plus: const Duration(seconds: 2));
      checker.takeReading(_at(source.insideWindow(0, plus: const Duration(seconds: 2))));
      source.scheduleOffset = source.afterWindow(0);
      checker.takeReading(_at(source.afterWindow(0)));
      checker.finish();

      expect(checker.violations, isEmpty,
          reason: 'the control\'s property is "the storm never AIMS at it", '
              'NOT "it is never disturbed" (11-03). Getting this wrong makes '
              'the strongest arm in the soak flaky rather than strong');
      expect(checker.ledger.total, 1,
          reason: 'the divergence is still on the RECORD — only the control '
              'ARM declines to judge it');
    });
  });

  group('the divergence ledger and its six attributed causes', () {
    test('resyncFailure: the client wrote it down and the keyframe answer is '
        'no', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 60);

      _judgeWindow(checker, source);
      source.panel(1).complaints.add('"$defaultPageSubscription" '
          '$unestablishedComplaint: Bad state. Its values are gone from the '
          'cache rather than left on screen under good quality');
      checker.finish();

      expect(checker.ledger.entries.single.cause,
          DivergenceCause.resyncFailure);
      expect(checker.ledger.residueOf(DivergenceCause.resyncFailure), 1,
          reason: 'keyframes do not arrive on a subscription that does not '
              'exist, so this one stays in residue and reopens the decision '
              'pointing at a different fix');
    });

    test('unknownHandle: a `u` naming a handle the session never announced',
        () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 60);

      _judgeWindow(checker, source);
      source.panel(1).complaints.add('update for '
          '"$defaultPageSubscription" named handle 9999, '
          '$unknownHandleComplaint');
      checker.finish();

      expect(checker.ledger.entries.single.cause,
          DivergenceCause.unknownHandle);
    });

    test('epochChange: recorded, and excluded from residue — both halves', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.epochBumpedAliases.add('ST101');
      source.panel(1).sayWithQuality(_resyncKey, 100, Quality.badCommFault);

      _judgeWindow(checker, source);
      checker.finish();

      expect(checker.ledger.entries.single.cause, DivergenceCause.epochChange,
          reason: 'an epoch bump legitimately marks the link\'s keys bad '
              'until the re-browse completes — the system working');
      expect(checker.ledger.total, 1,
          reason: 'EXCLUDED FROM RESIDUE, NEVER FROM THE RECORD: the event is '
              'in entries with its nth and its schedule offset, and it is '
              'streamed to the journal like every other');
      expect(checker.ledger.residueOf(DivergenceCause.epochChange), 1);
      expect(checker.ledger.residue, 0,
          reason: 'counted into residue it would dominate — the storm bumps '
              'epochs on purpose — and a residue dominated by the expected '
              'case hides whatever real finding sits under it');
      expect(checker.ledger.keyframesNotNeeded, isTrue);
    });

    test('generationChange: the judgement instant straddled a rebuild, and it '
        'stays in residue because it is a DETECTOR bug', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).say(_resyncKey, 60);

      source.scheduleOffset = source.insideWindow(0);
      checker.takeReading(_at(source.insideWindow(0)));
      // The gateway rebuilt the page between the sample before the window's
      // last one and the window's last one.
      source.panel(1).pageRebuilds = 4;
      source.scheduleOffset =
          source.insideWindow(0, plus: const Duration(seconds: 3));
      checker.takeReading(
          _at(source.insideWindow(0, plus: const Duration(seconds: 3))));
      source.scheduleOffset = source.afterWindow(0);
      checker.takeReading(_at(source.afterWindow(0)));
      checker.finish();

      expect(checker.ledger.entries.single.cause,
          DivergenceCause.generationChange);
      expect(checker.ledger.residue, 1,
          reason: 'discarding a replayed batch is correct, so a divergence '
              'attributed here means this checker compared a pre-snapshot '
              'cache with post-snapshot plant truth — a detector that cannot '
              'be trusted makes the verdict untrustworthy, and the verdict '
              'should say so rather than quietly subtract it');
    });

    test('lostPush: an established page holding a superseded value under GOOD '
        'quality, on a page the gateway then rebuilt', () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1).pageRebuilds = 3;
      source.panel(1).say(_resyncKey, 60);

      _judgeWindow(checker, source);
      // The tick-sequence detector fires and rebuilds the page. That rebuild is
      // the only public trace it leaves when it works.
      source.panel(1).pageRebuilds = 4;
      source.scheduleOffset =
          source.afterWindow(0) + const Duration(seconds: 1);
      checker.takeReading(
          _at(source.afterWindow(0) + const Duration(seconds: 1)));
      checker.finish();

      expect(checker.ledger.entries.single.cause, DivergenceCause.lostPush,
          reason: 'this is the case a periodic snapshot exists for — '
              '07-RESEARCH-PUBSUB Part 14 case 2 — and the doc on the enum arm '
              'says so where the reader of "lostPush=14" will find it');
      expect(checker.ledger.entries.single.generation, 4,
          reason: 'the generation is on the record because it is how G1 is '
              'told from G4');
    });

    test('unattributed: a panel behind the plant that no mechanism explains',
        () {
      final source = _ResyncSource();
      final checker = _resync(source);
      source.plantSweep = 100;
      source.panel(1)
          .sayWithQuality(_resyncKey, 60, Quality.uncertainNotYetKnown);

      _judgeWindow(checker, source);
      checker.finish();

      expect(checker.ledger.entries.single.cause,
          DivergenceCause.unattributed);
      expect(checker.ledger.unattributed, 1);
      expect(checker.ledger.keyframesNotNeeded, isFalse,
          reason: 'unattributed IS the verdict number — 11-CONTEXT ruling 5');
    });

    test('a widened lostPush detector cannot be told from a clean verdict, '
        'which is why every cause reads a surface the CLIENT publishes', () {
      // The taxonomy's six detectors read: two complaint strings quoted from
      // the client verbatim, the epoch bumps the DRIVER applied, the gateway's
      // own generation counter, and the quality on the value. Not one of them
      // reads a flag this harness planted — which is the property that makes
      // "widen it until unattributed reaches zero" a change somebody has to
      // argue for rather than one that hides in a boolean.
      final ledgerSource = File(
              'test/support/soak/checkers/eventual_resync.dart')
          .readAsStringSync();
      for (final surface in <String>[
        'unestablishedComplaint',
        'unknownHandleComplaint',
        'lostPushSurvivedRebuild',
        'epochBumpedAliases',
        'pageRebuilds',
      ]) {
        expect(ledgerSource, contains(surface),
            reason: 'the detector for one of the six stopped reading the '
                'shipped surface it was built from: $surface');
      }
    });

    test('the ledger is bounded and the overflow is counted', () {
      final source = _ResyncSource();
      final ledger = DivergenceLedger(source, capacity: 3);
      for (var i = 1; i <= 10; i++) {
        ledger.record(_event(i, DivergenceCause.unattributed));
      }

      expect(ledger.entries, hasLength(3),
          reason: 'a single stuck panel diverges on every key of every '
              'sample; retaining them would make this artifact the unbounded '
              'growth invariant 4 is asserting against');
      expect(ledger.entries.first.nth, 1,
          reason: 'the FIRST is kept rather than the last: what a soak needs '
              'is when the divergence started');
      expect(ledger.overflow, 7);
      expect(ledger.total, 10,
          reason: 'the counters are maintained outside the retained list, so a '
              'capped ledger still reports the whole run — a cap without a '
              'counter would report three for a run that had ten');
      expect(ledger.verdictBlock, contains('total divergence events         : 10'));
      expect(ledger.verdictBlock, contains('capped at 3'));
    });
  });

  group('the keyframe verdict, against a threshold set before the run', () {
    test('the block prints in the exact specified shape, line by line', () {
      final source = _ResyncSource()..seed = 11;
      final ledger = DivergenceLedger(source)
        ..record(_event(1, DivergenceCause.lostPush, isControl: true));
      final lines = ledger.verdictBlock.split('\n');

      expect(lines[0], 'divergence verdict (seed=11, duration=90s, panels=3):');
      expect(lines[1], '  total divergence events         : 0');
      expect(lines[2], '  healed within the stable window : 0');
      expect(lines[3], '  RESIDUE (unhealed at window end): 0');
      expect(lines[4], '  UNATTRIBUTED (healed or not)    : 0');
      expect(lines[5],
          '  residue by cause: lostPush=0 unknownHandle=0 generationChange=0');
      expect(lines[6],
          '                    resyncFailure=0 epochChange=0 unattributed=0');
      expect(lines[7], '  KEYFRAME VERDICT: not needed');
      expect(lines[8], contains('ledger control: 1 event recorded, '
          'attributed lostPush'));
      expect(lines, hasLength(9),
          reason: 'this block is pasted into the milestone audit, quoted in '
              'STATE.md and read months from now. A shape that drifts between '
              'runs is a shape nobody can diff, so drift fails here');
    });

    test('the block prints BOTH terms the verdict turns on, and a healed '
        'unattributed event proves they are different numbers', () {
      // **`unattributed` is half of `keyframesNotNeeded` and the block did not
      // print it.** The predicate is `unattributed <= 0 && residue <= 0`,
      // where `unattributed` is `countOf(unattributed)` — every unattributed
      // event, HEALED OR NOT — and `residue` sums `residueOf` over the
      // non-epoch causes, unhealed only. The only `unattributed` in the block
      // was the one inside the residue-by-cause line, which is
      // `residueOf(unattributed)`: a different number.
      //
      // So a run whose unattributed divergences all healed printed
      // `total 3 / healed 3 / RESIDUE 0 / ... unattributed=0` and then
      // `KEYFRAME VERDICT: needed, evidence above` — with no evidence above.
      // The milestone's headline decision was closed on "unattributed 0,
      // residue 0" read out of a block that did not contain the first number.
      final ledger = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..record(_event(2, DivergenceCause.unattributed, healedWithinMs: 900))
        ..record(_event(3, DivergenceCause.unattributed, healedWithinMs: 1200))
        ..record(_event(4, DivergenceCause.unattributed, healedWithinMs: 800));

      expect(ledger.unattributed, 3);
      expect(ledger.residue, 0, reason: 'all three healed inside the window');
      expect(ledger.keyframesNotNeeded, isFalse,
          reason: 'the predicate reads countOf, so it says NEEDED');

      expect(ledger.verdictBlock,
          contains('UNATTRIBUTED (healed or not)    : 3'),
          reason: 'the verdict says needed and the reader must be able to see '
              'WHY from the same block. A verdict whose asserted number is '
              'printed nowhere is the M-08 shape on the headline line');
      expect(ledger.verdictBlock, contains('RESIDUE (unhealed at window end): 0'),
          reason: 'and the other term stays visible beside it, or the reader '
              'swaps one lie for another');
    });

    test('a clean verdict passes the assertion; a residue-carrying one fails '
        'it and says the DECISION must be revisited', () {
      // **The verdict was print-only.** `keyframesNotNeeded`, `unattributed`
      // and `residue` were read in exactly one file — this one, against
      // hand-built ledgers — and `soak_test.dart` read none of them. The
      // ledger's own `violationLog` fires on one condition, the verdict FILE
      // failing to write, so `KEYFRAME VERDICT: needed` printed and the lane
      // went green, on the ninety-second arm and the thirty-five-minute job
      // alike. A decision number that cannot change visibly is not a decision
      // number.
      final clean = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true));
      expect(() => assertKeyframeVerdictIsClean(clean), returnsNormally);

      final dirty = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..record(_event(2, DivergenceCause.unattributed));

      Object? thrown;
      try {
        assertKeyframeVerdictIsClean(dirty);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull, reason: 'residue 1 against a threshold of 0');
      final message = thrown.toString();
      expect(message, contains('keyframe decision'),
          reason: 'a red here is a DESIGN QUESTION REOPENING, not a fault. '
              'Whoever reads this at 3 a.m. has to know which of the two it '
              'is, or they will go looking for a broken pipe');
      expect(message, contains('revisit'));
      expect(message, contains('divergences.jsonl'),
          reason: 'and it must name where the events are, not merely that '
              'there were some');
    });

    test('the ledger control cannot trip the assertion, and that is one early '
        'return', () {
      // **The pin that stands between this assertion and a permanently red
      // lane.** The control is recorded with `healedWithinMs: null` — it is
      // unhealed BY CONSTRUCTION, because it substitutes a value nothing in
      // the run will ever supply again. If it reached the counters it would be
      // residue on every run for ever.
      //
      // What stops it is `record()` returning at the top on `event.isControl`,
      // before `_total`, `_byCause`, `_residueByCause` and `_retain`. One
      // branch, one call site (`eventual_resync.dart` sets `isControl: true`
      // in exactly one place). Nothing failed if somebody deleted it: the
      // cases below assert the control's EFFECTS, not that the isolation is
      // what produces them, and with the verdict unasserted on composed runs
      // the lane would not have noticed either.
      //
      // Deliberately given the most dangerous cause available rather than the
      // `lostPush` the real control uses, so the pin holds even if the
      // taxonomy's attribution of the control ever changes.
      final ledger = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.unattributed, isControl: true));

      expect(ledger.unattributed, 0,
          reason: 'an unhealed, unattributed CONTROL event must not reach the '
              'counters — it is the verdict\'s warrant, not one of the run\'s '
              'divergences');
      expect(ledger.residue, 0);
      expect(ledger.total, 0);
      expect(ledger.keyframesNotNeeded, isTrue);
      expect(() => assertKeyframeVerdictIsClean(ledger), returnsNormally,
          reason: 'if this ever fails, EVERY push is red for ever and the '
              'cause is two lines in DivergenceLedger.record');
      expect(ledger.judgedSamples, 1,
          reason: 'and it still counts as the reading that clears the vacuity '
              'gate, which is the whole reason the control exists');
    });

    test('the composed run ASSERTS the verdict, on every arm, and not only '
        'prints it', () {
      // **A structural pin, and it is the only honest instrument for this.**
      // The behaviour — a composed run going red on residue — cannot be
      // produced on demand: three composed runs have recorded zero divergence
      // events, the negative branch has never fired on one, and manufacturing
      // a real divergence would mean corrupting a frame through a seam the
      // soak does not have (`eventual_resync.dart` explains why the control
      // substitutes an answer instead). So what is pinned is that the call
      // site exists, in the same idiom as invariant 5's `_resyncComplained`
      // pin and invariant 4's `_debugHistory` pin.
      //
      // It is pinned rather than trusted because the whole finding was that
      // this number printed and nothing read it, on both arms, for the length
      // of the milestone. There is ONE `_runSoak`, so one call site covers the
      // ninety-second arm, the thirty-five-minute job and the auxiliary arms —
      // an assertion that ran on one arm and not the other would be "judged on
      // a column where it never ran", which is the failure this phase keeps
      // finding.
      final soakTest = File('test/soak/soak_test.dart');
      expect(soakTest.existsSync(), isTrue,
          reason: 'the pin is worthless if the path rots: ${soakTest.path}');
      final source = soakTest.readAsStringSync();

      expect(source, contains('assertKeyframeVerdictIsClean'),
          reason: 'the keyframe verdict is the milestone\'s headline decision '
              'number (11-CONTEXT ruling 5). Without this call the composed '
              'run PRINTS "KEYFRAME VERDICT: needed" and exits 0 — which is '
              'what it did for the whole of Phase 11');
      expect(RegExp(r'_runSoak').allMatches(source).length,
          greaterThanOrEqualTo(2),
          reason: 'one composed entry point is what makes "both arms" true by '
              'construction rather than by two call sites staying in step. If '
              'this ever becomes two functions, the assertion has to be in '
              'both and this pin has to say so');
    });

    test('one unhealed unattributed event prints NEEDED', () {
      final ledger = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..record(_event(2, DivergenceCause.unattributed));

      expect(ledger.unattributed, 1);
      expect(ledger.residue, 1);
      expect(ledger.verdictBlock, contains('KEYFRAME VERDICT: needed, '
          'evidence above'));
    });

    test('an empty ledger whose control FIRED prints not needed; one whose '
        'control did NOT fire prints neither and fails the vacuity gate', () {
      final fired = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true));
      expect(fired.verdictBlock, contains('KEYFRAME VERDICT: not needed'));
      expect(() => assertNoVacuousVerdict(<InvariantChecker>[fired]),
          returnsNormally);

      final silent = DivergenceLedger(_ResyncSource());
      expect(silent.controlLine, contains('DID NOT FIRE'));
      expect(silent.controlLine, contains('T-11-25'));
      expect(silent.judgedSamples, 0);
      expect(
          () => assertNoVacuousVerdict(<InvariantChecker>[silent]),
          throwsA(isA<TestFailure>().having((one) => one.message, 'message',
              contains('divergenceLedger'))),
          reason: 'a ledger that recorded nothing all run reads exactly like a '
              'clean verdict, so the number must never be read without the '
              'evidence that the recorder works');
    });

    test('the threshold is zero, it is a named constant, and it cites the '
        'ruling that set it before the run', () {
      expect(keyframeVerdictThreshold, 0,
          reason: '11-CONTEXT ruling 5 — the strictest honest reading of the '
              'user\'s ruling. There is no tolerance band, because a threshold '
              'chosen after seeing the numbers is a description of the numbers '
              'wearing a threshold\'s clothes');

      final source = File('test/support/soak/divergence_ledger.dart')
          .readAsStringSync();
      expect(source, contains('11-CONTEXT ruling 5'));
      expect(source, contains('set before the run'),
          reason: 'the citation is what makes the verdict defensible, and it '
              'has to be beside the constant rather than in a summary');
    });

    test('a HEALED unattributed event still counts — the threshold cannot be '
        'moved after the fact', () {
      // **The pin, and the sabotage that produced it.** Redefining
      // `unattributed` to skip events that healed within thirty seconds — the
      // most reasonable-sounding relaxation available, and the one a person
      // staring at a red verdict would reach for — flipped this ledger from
      // *needed* to *not needed* and left the ENTIRE meta suite green. Nothing
      // in the repository failed. 11-05b's structural-pin idiom is the answer:
      // the rule that cannot be checked by a behavioural arm gets asserted
      // directly.
      //
      // 11-CONTEXT ruling 5 counts EVENTS, not survivors: a divergence nobody
      // could attribute is a divergence nobody could attribute, and whether the
      // pipe happened to recover from it afterwards is a different question
      // from whether this harness understood it.
      final ledger = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..record(_event(2, DivergenceCause.unattributed, healedWithinMs: 1200))
        ..record(
            _event(3, DivergenceCause.unattributed, healedWithinMs: 28000));

      expect(ledger.residue, 0,
          reason: 'both healed, so neither is residue — which is exactly the '
              'state in which a moved threshold looks harmless');
      expect(ledger.unattributed, 2,
          reason: 'a threshold that discounted these two would print "not '
              'needed" on a run that could not explain two of its own '
              'divergences. A threshold chosen after seeing the numbers is not '
              'a threshold');
      expect(ledger.keyframesNotNeeded, isFalse);
      expect(ledger.verdictBlock, contains('needed, evidence above'));
    });

    test('an OVERFLOWED ledger still streams every event to divergences.jsonl',
        () async {
      // **The doc and the verdict block both promise this and neither was
      // true.** `takeReading` streams `for (i = _streamed; i < _entries.length;
      // i++)`, and `_retain` stops appending to `_entries` at `capacity`. So
      // once the ledger overflows, `_entries.length` is pinned, `_streamed`
      // catches up to it, and the guard `if (_streamed >= _entries.length)
      // return` makes every later tick a no-op. The events past the cap reach
      // NEITHER the retained list nor the file.
      //
      // The doc directly above `takeReading` says "**Streamed rather than
      // accumulated**, so a thirty-five-minute run whose ledger overflowed
      // still has every event on disk", and the verdict block tells the reader
      // the overflowed events are "counted above and in divergences.jsonl
      // ONLY". On the one run where the keyframe decision flips and the
      // per-event record IS the evidence, the reader follows that instruction
      // and gets nothing after event #200.
      final dir = _tempJournal();
      final source = _ResyncSource()..journalPath = dir;
      final ledger = DivergenceLedger(source, capacity: 3);
      // Ticked between events, the way the driver ticks it: the first few are
      // streamed, and then the ledger overflows and every later tick is a
      // no-op because the cursor has caught up with a list that stopped
      // growing.
      for (var i = 1; i <= 10; i++) {
        ledger.record(_event(i, DivergenceCause.unattributed));
        ledger.takeReading(_at(Duration(seconds: i)));
      }
      await ledger.flushStream();

      final file = File('$dir/$divergenceFileName');
      final lines = file
          .readAsLinesSync()
          .where((one) => one.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(10),
          reason: 'ten events were recorded and the file is THE record — the '
              'retained list is only what the verdict block prints. Three '
              'lines here is the ledger silently forgetting seven events it '
              'told the reader to look for in this file');
      expect(ledger.overflow, 7);
      expect(ledger.total, 10);
      // Every line a whole JSON object: two append sinks open on one file can
      // interleave mid-line, and a corrupted record in the artifact whose
      // whole job is to be machine-readable is worse than a short one.
      for (final line in lines) {
        expect(() => jsonDecode(line), returnsNormally,
            reason: 'unparseable line in $divergenceFileName: $line');
      }
      expect(
          <int>[
            for (final line in lines)
              (jsonDecode(line) as Map<String, Object?>)['nth']! as int,
          ],
          <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
          reason: 'in order, once each — a cursor advanced before the flush '
              'loses lines and a sink reopened per tick can duplicate them');
    });

    test('the verdict is written to verdict.txt and matches stdout', () {
      final dir = _tempJournal();
      final source = _ResyncSource()..journalPath = dir;
      final ledger = DivergenceLedger(source)
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..finish();

      final written = File('$dir/$verdictFileName').readAsStringSync();
      expect(written.trim(), ledger.verdictBlock.trim(),
          reason: '11-07 uploads this file as the CI artifact; a copy that '
              'differed from stdout would be two verdicts for one run');
    });

    test('a NEEDED verdict records no violation — residue is evidence about a '
        'design decision, not a broken pipe', () {
      final ledger = DivergenceLedger(_ResyncSource())
        ..record(_event(1, DivergenceCause.lostPush, isControl: true))
        ..record(_event(2, DivergenceCause.unattributed))
        ..record(_event(3, DivergenceCause.unattributed));

      expect(ledger.verdictBlock, contains('needed, evidence above'));
      expect(ledger.violations, isEmpty,
          reason: 'conflating the two would make the keyframe question '
              'un-askable without a red build, which is the one way to '
              'guarantee nobody ever asks it. The test fails on invariant '
              'violations; the verdict is a finding for the user');
    });

    test('an invariant violation DOES fail, and it comes from the checker',
        () {
      final source = _ResyncSource(windows: const <StableWindow>[]);
      final checker = _resync(source)..finish();
      expect(checker.violations, isNotEmpty);
      expect(checker.ledger.violations, isEmpty);
    });

    test('nothing resembling a keyframe was built', () {
      final hits = <String>[];
      for (final package in <String>[
        '../tfc_relay_local/lib',
        '../tfc_relay_client/lib',
        '../tfc_relay_server/lib',
        '../tfc_relay_protocol/lib',
      ]) {
        final dir = Directory(package);
        if (!dir.existsSync()) continue;
        for (final file in dir.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          // Identifiers, not prose. The word appears in one doc comment that
          // predates this phase — `connection_supervisor.dart:655`, *"Not left
          // to Phase 8's keyframes"*, written in Phase 7 to say why the tick
          // carries a sequence — and a fence that failed on somebody EXPLAINING
          // why keyframes were not built would be a fence nobody could hold.
          // What the fence is about is a keyframe being BUILT, so what is swept
          // for is a line of code carrying the name.
          for (final line in file.readAsLinesSync()) {
            final code = line.trim();
            if (code.startsWith('//') || code.startsWith('///')) continue;
            if (code.startsWith('*') || code.startsWith('/*')) continue;
            if (code.toLowerCase().contains('keyframe')) {
              hits.add('${file.path}: $code');
            }
          }
        }
      }
      expect(hits, isEmpty,
          reason: 'the scope fence, made mechanical: no keyframes are built in '
              'this phase regardless of what the verdict prints. The ledger '
              'produces the evidence; building is a post-milestone decision '
              'with the user (11-CONTEXT scope fences). Found in: $hits');
    });
  });
}

// ------------------------------------------------------- invariant 3's doubles

/// The one key the resync arms compare, on an alias the soak really carries.
const String _resyncKey = 'ST101.CN01.MOT01.setpoint';

/// Takes a reading inside window [index] and then the first one past its end,
/// which is the judgement instant.
///
/// **Two readings and not one**, because the window's end is judged on what
/// the LAST sample inside it saw: by the time the checker knows a window has
/// ended, the storm has been free to resume for a tick, and a divergence
/// recorded from a reading taken after the quiet is over is a divergence
/// attributed to the wrong conditions.
void _judgeWindow(EventualResyncChecker checker, _ResyncSource source,
    {int index = 0}) {
  source.scheduleOffset = source.insideWindow(index);
  checker.takeReading(_at(source.insideWindow(index)));
  source.scheduleOffset = source.afterWindow(index);
  checker.takeReading(_at(source.afterWindow(index)));
}

EventualResyncChecker _resync(_ResyncSource source) =>
    EventualResyncChecker(source, DivergenceLedger(source));

/// One synthetic event, for the arms that are about the ledger rather than
/// about the checker that feeds it.
DivergenceEvent _event(int nth, DivergenceCause cause,
        {bool isControl = false, int? healedWithinMs}) =>
    DivergenceEvent(
      nth: nth,
      panelId: 'panel-1',
      subId: defaultPageSubscription,
      key: _resyncKey,
      scheduleOffset: Duration(seconds: nth),
      wallOffsetMs: nth * 1000,
      cause: cause,
      clientValue: 80,
      plantValue: 100,
      clientQuality: Quality.good,
      plantQuality: Quality.good,
      generation: 1,
      windowIndex: 0,
      healedWithinMs: healedWithinMs,
      isControl: isControl,
    );

/// A convergence source whose plant and panels are set by hand.
///
/// The windows default to the three `computeStableWindows` really produces for
/// the ninety-second lane, so an arm that steps the schedule offset through
/// them is stepping through the shape the run actually has.
final class _ResyncSource implements SoakResyncSource {
  _ResyncSource({List<String>? keys, List<StableWindow>? windows, int panels = 3})
      : freshnessKeys = keys ?? const <String>[_resyncKey],
        stableWindows =
            windows ?? computeStableWindows(const Duration(seconds: 90)),
        panelResyncViews = <_ResyncPanel>[
          for (var i = 0; i < panels; i++) _ResyncPanel(i),
        ];

  @override
  int seed = 11;

  @override
  Duration declaredDuration = const Duration(seconds: 90);

  @override
  Duration scheduleOffset = Duration.zero;

  @override
  int controlPanelIndex = 0;

  @override
  int plantWideArmsApplied = 0;

  @override
  final List<_ResyncPanel> panelResyncViews;

  @override
  final List<String> freshnessKeys;

  @override
  final List<StableWindow> stableWindows;

  @override
  Duration plantSweepPeriod = const Duration(milliseconds: 250);

  @override
  final Set<String> epochBumpedAliases = <String>{};

  @override
  String journalPath = 'build/soak-meta';

  /// The sweep counter's current value.
  int plantSweep = 0;

  /// Keys a `PlantMutate` pinned.
  final Map<String, Object?> overrides = <String, Object?>{};

  @override
  SoakPlantTruth? plantTruthFor(String key) {
    if (!key.startsWith('ST101') && !key.startsWith('BAADER')) return null;
    if (overrides.containsKey(key)) {
      return SoakPlantTruth(value: overrides[key], overridden: true);
    }
    return SoakPlantTruth(
        value: plantSweep, overridden: false, sweepIndex: plantSweep);
  }

  _ResyncPanel panel(int index) => panelResyncViews[index];

  /// An offset inside window [index], derived rather than assumed.
  ///
  /// **Derived, because the first version of these arms assumed the windows
  /// began at ten seconds and they do not.** `computeStableWindows` spreads
  /// them at `duration / (N + 1)`, so at ninety seconds the first is
  /// 22.5–32.5 s, and every case that stepped through 11 s and 30 s was
  /// stepping into open storm and then into the middle of window 0 — which is
  /// what the RED reading actually caught. Deriving them here makes these arms
  /// immune to a generator change as well as correct now.
  Duration insideWindow(int index, {Duration plus = Duration.zero}) =>
      stableWindows[index].start + const Duration(milliseconds: 500) + plus;

  /// The first offset past window [index], where its residue is settled.
  Duration afterWindow(int index) =>
      stableWindows[index].end + const Duration(seconds: 1);
}

final class _ResyncPanel implements SoakPanelResyncView {
  _ResyncPanel(this.index);

  @override
  final int index;

  @override
  String get name => 'panel-$index';

  @override
  bool viewIsStale = false;

  @override
  bool pageIsStale = false;

  @override
  bool established = true;

  @override
  final List<String> complaints = <String>[];

  @override
  int pageRebuilds = 1;

  final Map<String, DynamicValue> _values = <String, DynamicValue>{};

  void say(String key, Object? value) =>
      _values[key] = DynamicValue(value: value, quality: Quality.good);

  void sayWithQuality(String key, Object? value, Quality quality) =>
      _values[key] = DynamicValue(value: value, quality: quality);

  @override
  DynamicValue? read(String key) => _values[key];
}

// ------------------------------------------------------- the structural sweep

/// The name no assertion may be written against.
const String _rssNeedle = 'currentRss';

/// One occurrence, with enough around it to judge.
typedef _Hit = ({String file, int line, String text, List<String> neighbours});

/// Every occurrence of [needle] under the soak trees.
///
/// **This file excludes itself, by name and for one reason**: the case above
/// carries the needle as a literal, so a sweep that read its own source would
/// find its own pattern and report the doctrine broken by the test that
/// enforces it. The needle-is-real arm is what stops that exclusion hiding a
/// broken sweep — the same shape `soak_manifest_test.dart` uses for its own.
List<_Hit> _sweepSoakTreeFor(String needle) {
  const roots = <String>['test/support/soak', 'test/soak'];
  const excluded = 'soak_meta_test.dart';
  final hits = <_Hit>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith(excluded)) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains(needle)) continue;
        hits.add((
          file: entity.path,
          line: i + 1,
          text: lines[i],
          neighbours: lines.sublist(
              i - 3 < 0 ? 0 : i - 3, i + 4 > lines.length ? lines.length : i + 4),
        ));
      }
    }
  }
  return hits;
}

/// Whether a line actually READS the getter, as opposed to naming it.
///
/// Three ways a line can carry the name and not be a memory assertion: a doc
/// comment, an ordinary comment, and a string literal. The third is not a
/// technicality — `soak_registry.dart`'s deviation 2 quotes
/// `long_outage_gate_test.dart`'s doctrine **verbatim**, and that paragraph
/// contains the getter's name twice by design, because *"paraphrase it and
/// nobody can check the deviation against the catalogue"*. A sweep that read
/// the quotation as code would force the one entry that declares this departure
/// to stop quoting the text it departs from.
bool _readsIt(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('///') || trimmed.startsWith('//')) return false;
  var quote = '';
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote.isEmpty && (ch == "'" || ch == '"')) {
      quote = ch;
    } else if (quote == ch && (i == 0 || line[i - 1] != r'\')) {
      quote = '';
    } else if (quote.isEmpty && line.startsWith(_rssNeedle, i)) {
      return true;
    }
  }
  return false;
}

/// Hits with an `expect(` within three lines either side.
List<String> _expectNear(List<_Hit> hits) => <String>[
      for (final hit in hits)
        if (hit.neighbours.any((line) => line.contains('expect(')))
          '${hit.file}:${hit.line}',
    ];

// ------------------------------------------------------------- the fixtures

/// A clock stopped at [elapsed], for the arms that need an offset rather than a
/// wait.
SoakClock _at(Duration elapsed) =>
    SoakClock.frozenAt(elapsed, declaredDuration: const Duration(minutes: 1));

/// A journal directory an auxiliary case owns, so it cannot overwrite the
/// artifact the real arm writes to `build/soak/`.
/// Every `(file, panel)` pair whose file contains that panel's token literal.
///
/// Reads the tokens from [soakTokenForPanel] rather than restating them, so the
/// sweep cannot drift away from what the fixture actually presents.
List<String> _credentialHits(String path) {
  final hits = <String>[];
  for (final entity in Directory(path).listSync(recursive: true)) {
    if (entity is! File) continue;
    final text = entity.readAsStringSync();
    for (var panel = 0; panel < 16; panel++) {
      if (text.contains(soakTokenForPanel(panel))) {
        hits.add('${entity.uri.pathSegments.last}: panel-$panel');
      }
    }
  }
  return hits;
}

String _tempJournal() {
  final dir = Directory.systemTemp.createTempSync('relay-soak-meta-');
  addTearDown(() => _deleteTempTolerantly(dir));
  return dir.path;
}

/// Deletes a temp directory, tolerating a Windows handle that has not closed.
///
/// `deleteSync(recursive: true)` throws `PathAccessException: The process
/// cannot access the file because it is being used by another process` when any
/// handle under the directory is still open. POSIX unlinks regardless, which is
/// why this only ever bites on the Windows agent — measured there as
/// `relay-soak-meta-*` failing teardown and taking an otherwise green case with
/// it.
///
/// Retries briefly, because the lingering handle is usually milliseconds from
/// closing, and then **gives up without failing**: this is cleanup, not a
/// property. The OS reclaims its own temp directory, and a case that passed its
/// assertions has not become wrong because a directory outlived it. The give-up
/// is printed rather than silent, so a genuine handle leak is still visible to
/// anyone reading the log.
void _deleteTempTolerantly(Directory dir) {
  for (var attempt = 0; attempt < 5; attempt++) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 100));
    }
  }
  if (dir.existsSync()) {
    print('note: could not delete ${dir.path} — a handle is still open. '
        'Left for the OS; the case itself is unaffected.');
  }
}


/// A freshness source whose panels hold still, for the unit arms.
final class _Source implements SoakFreshnessSource {
  _Source({
    this.seed = 11,
    List<String>? keys,
    int panels = 3,
  })  : freshnessKeys = keys ?? const <String>['ST101.CN01.MOT01.setpoint'],
        panelViews = <_Panel>[
          for (var i = 0; i < panels; i++) _Panel(i),
        ];

  @override
  final int seed;

  @override
  Duration declaredDuration = const Duration(minutes: 1);

  @override
  final List<String> freshnessKeys;

  @override
  final List<_Panel> panelViews;

  @override
  Duration scheduleOffset = Duration.zero;

  Duration get offset => scheduleOffset;
  set offset(Duration value) => scheduleOffset = value;

  @override
  int controlPanelIndex = 0;

  @override
  int plantWideArmsApplied = 0;

  @override
  Duration freshnessBudget = const Duration(seconds: 12);

  /// What the soak's plant is publishing, for the keys a case has scripted.
  ///
  /// Empty by default, so every case written before the pinned-key rule
  /// existed keeps answering `null` — "no link carries this key" — and is
  /// judged on the arrival proxy alone.
  final Map<String, SoakPlantTruth> plantTruth = <String, SoakPlantTruth>{};

  @override
  SoakPlantTruth? plantTruthFor(String key) => plantTruth[key];

  _Panel panel(int index) => panelViews[index];
}

final class _Panel implements SoakPanelView {
  _Panel(this.index);

  @override
  final int index;

  @override
  String get name => 'panel-$index';

  @override
  bool viewIsStale = false;

  @override
  bool pageIsStale = false;

  final Map<String, DynamicValue> _values = <String, DynamicValue>{};

  /// Delivers one value, exactly as a frame arriving would.
  void say(String key, Object? value) {
    _values[key] = DynamicValue(value: value, quality: Quality.good);
  }

  /// The placeholder a real panel renders before its first snapshot lands.
  void sayNothingYet(String key) {
    _values[key] =
        DynamicValue(value: null, quality: Quality.uncertainNotYetKnown);
  }

  @override
  DynamicValue? read(String key) => _values[key];
}

/// A live source with one panel's freshness verdict overridden to `fresh`.
///
/// **Test-only, and a substitute** — see the control's own comment for what it
/// stands in for. It wraps rather than replaces: every panel but [liar] is the
/// real one, and even [liar]'s values are the real client's.
final class _LyingSource implements SoakFreshnessSource {
  _LyingSource(this._real, {required this.liar});

  final SoakFreshnessSource _real;
  final int liar;

  @override
  int get seed => _real.seed;

  @override
  Duration get declaredDuration => _real.declaredDuration;

  @override
  Duration get scheduleOffset => _real.scheduleOffset;

  @override
  List<String> get freshnessKeys => _real.freshnessKeys;

  @override
  int get controlPanelIndex => _real.controlPanelIndex;

  @override
  int get plantWideArmsApplied => _real.plantWideArmsApplied;

  @override
  Duration get freshnessBudget => _real.freshnessBudget;

  @override
  SoakPlantTruth? plantTruthFor(String key) => _real.plantTruthFor(key);

  @override
  List<SoakPanelView> get panelViews => <SoakPanelView>[
        for (final view in _real.panelViews)
          view.index == liar ? _LyingPanelView(view) : view,
      ];
}

/// One panel that reports fresh whatever its own watchdog says.
final class _LyingPanelView implements SoakPanelView {
  _LyingPanelView(this._real);

  final SoakPanelView _real;

  @override
  int get index => _real.index;

  @override
  String get name => _real.name;

  @override
  bool get viewIsStale => false;

  @override
  bool get pageIsStale => false;

  @override
  DynamicValue? read(String key) {
    final value = _real.read(key);
    // The quality is part of the verdict a widget renders, so a lie that left
    // `badStale` on the value would be caught by the quality arm rather than by
    // the age arm and would prove the wrong thing.
    return value?.copyWith(quality: Quality.good);
  }
}

/// A write source driven by hand, for the arms that need a specific sequence
/// rather than a storm.
final class _WriteSource implements SoakWriteSource {
  _WriteSource({int ledgerCapacity = appliedWriteLedgerCapacity})
      : appliedWrites = AppliedWriteLedger(capacity: ledgerCapacity);

  @override
  final int seed = 11;

  @override
  Duration declaredDuration = const Duration(minutes: 1);

  @override
  Duration scheduleOffset = Duration.zero;

  @override
  final AppliedWriteLedger appliedWrites;

  final List<SoakWriteRecord> _records = <SoakWriteRecord>[];
  final List<String> _unresolved = <String>[];
  final Map<String, SoakWriteRecord> _issued = <String, SoakWriteRecord>{};
  int _nth = 0;

  @override
  List<SoakWriteRecord> get writeRecords =>
      List<SoakWriteRecord>.unmodifiable(_records);

  @override
  List<String> get unresolvedCmds => List<String>.unmodifiable(_unresolved);

  @override
  List<String> get orphanedCmds => List<String>.unmodifiable(_orphaned);

  @override
  List<SoakPanelRestart> get panelRestarts =>
      List<SoakPanelRestart>.unmodifiable(_restarts);

  final List<String> _orphaned = <String>[];
  final List<SoakPanelRestart> _restarts = <SoakPanelRestart>[];

  /// A cmd left behind on a client a redial retired.
  void orphaned(String cmd) => _orphaned.add(cmd);

  /// A client replacement, as `GateBFixture.redial` performs it.
  void restarted(String panel, Duration at) =>
      _restarts.add(SoakPanelRestart(panel: panel, at: at));

  void issue(String cmd,
      {required String panel, required String key, required Object? value}) {
    final record = SoakWriteRecord(
      nth: ++_nth,
      cmd: cmd,
      panel: panel,
      key: key,
      value: value,
      stage: SoakWriteStage.issued,
      at: scheduleOffset,
      probe: true,
    );
    _issued[cmd] = record;
    _records.add(record);
  }

  void direct(String cmd, String outcome,
      {required bool reachedASocket, Duration? at}) {
    _append(cmd, outcome, SoakWriteStage.direct, at,
        reachedASocket: reachedASocket);
  }

  void resolve(String cmd, String outcome, {Duration? at}) {
    _append(cmd, outcome, SoakWriteStage.lateResolution, at,
        reachedASocket: true);
  }

  /// Issue and settle in one call, for the arms that only need the outcome.
  void settled(String cmd, String outcome) {
    issue(cmd, panel: 'panel-1', key: 'ST101.CN01.MOT01.setpoint', value: 1);
    direct(cmd, outcome, reachedASocket: true);
  }

  void stillUnresolved(String cmd) => _unresolved.add(cmd);

  void _append(String cmd, String outcome, SoakWriteStage stage, Duration? at,
      {required bool reachedASocket}) {
    final issued = _issued[cmd];
    _records.add(SoakWriteRecord(
      nth: issued?.nth ?? -1,
      cmd: cmd,
      panel: issued?.panel ?? 'panel-1',
      key: issued?.key ?? '(unknown)',
      value: issued?.value,
      stage: stage,
      outcome: outcome,
      reachedASocket: reachedASocket,
      at: at ?? scheduleOffset,
      probe: true,
    ));
  }
}

// ----------------------------------------------- invariant 4's and 5's fakes

/// A structure source driven by hand, for the arms that need a specific series
/// rather than a storm.
///
/// It holds the reading rather than computing one, which is the property the
/// slope arms need: a series is a sequence of numbers somebody chose, so the
/// case can state the shape it is testing in the loop that drives it.
final class _StructureSource implements SoakStructureSource {
  _StructureSource({this.seed = 11, int panels = 1})
      : _panels = <int, Map<String, int>>{
          for (var i = 0; i < panels; i++)
            i: <String, int>{
              for (final structure in boundedMemoryPanelStructures)
                structure: 0,
            },
        };

  @override
  final int seed;

  @override
  Duration declaredDuration = const Duration(minutes: 1);

  @override
  Duration scheduleOffset = Duration.zero;

  Duration get offset => scheduleOffset;
  set offset(Duration value) => scheduleOffset = value;

  @override
  int controlPanelIndex = 0;

  @override
  int plantWideArmsApplied = 0;

  final Map<int, Map<String, int>> _panels;

  /// The plant-wide half, mutable so a case can drive one structure.
  final Map<String, int> plantWide = <String, int>{
    for (final structure in boundedMemoryPlantWideStructures) structure: 0,
  };

  /// Structures this "platform" cannot read, with the reason.
  final Map<String, String> skips = <String, String>{};

  /// Structures this "checkpoint" is carrying rather than reading.
  final Set<String> carriedForward = <String>{};

  Map<String, int> panel(int index) => _panels[index]!;

  @override
  SoakStructureReading readStructures() => SoakStructureReading(
        perPanel: <int, Map<String, int>>{
          for (final entry in _panels.entries)
            entry.key: Map<String, int>.of(entry.value),
        },
        plantWide: <String, int>{
          for (final entry in plantWide.entries)
            if (!skips.containsKey(entry.key)) entry.key: entry.value,
        },
        skips: Map<String, String>.of(skips),
        carriedForward: Set<String>.of(carriedForward),
      );
}

/// A structure source that throws, for the [GuardedSampling] arm.
final class _ThrowingStructureSource implements SoakStructureSource {
  @override
  int get seed => 11;

  @override
  Duration get declaredDuration => const Duration(minutes: 1);

  @override
  Duration get scheduleOffset => Duration.zero;

  @override
  int get controlPanelIndex => 0;

  @override
  int get plantWideArmsApplied => 0;

  @override
  SoakStructureReading readStructures() =>
      throw StateError('the composed pipe went away mid-reading');
}

/// The positive control: one panel's structure grows by one at every reading
/// and never comes back down.
///
/// A decorator over a real answer rather than a second source — the shape
/// `soak_observables.dart` argues for. Everything but the one structure on the
/// one panel is whatever the source said.
final class _LeakingStructureSource implements SoakStructureSource {
  _LeakingStructureSource(this._real,
      {required this.panel, required this.structure});

  final SoakStructureSource _real;
  final int panel;
  final String structure;
  int _held = 0;

  @override
  int get seed => _real.seed;

  @override
  Duration get declaredDuration => _real.declaredDuration;

  @override
  Duration get scheduleOffset => _real.scheduleOffset;

  @override
  int get controlPanelIndex => _real.controlPanelIndex;

  @override
  int get plantWideArmsApplied => _real.plantWideArmsApplied;

  @override
  SoakStructureReading readStructures() {
    final real = _real.readStructures();
    final perPanel = <int, Map<String, int>>{
      for (final entry in real.perPanel.entries)
        entry.key: Map<String, int>.of(entry.value),
    };
    perPanel[panel]?[structure] = ++_held;
    return SoakStructureReading(
      perPanel: perPanel,
      plantWide: real.plantWide,
      skips: real.skips,
    );
  }
}

/// A log source driven by hand.
final class _LogSource implements SoakLogSource {
  _LogSource({this.seed = 11, int panels = 1})
      : panelLogs = <_PanelLog>[
          for (var i = 0; i < panels; i++) _PanelLog(i),
        ];

  @override
  final int seed;

  @override
  Duration declaredDuration = const Duration(minutes: 1);

  @override
  Duration scheduleOffset = Duration.zero;

  Duration get offset => scheduleOffset;
  set offset(Duration value) => scheduleOffset = value;

  @override
  int controlPanelIndex = 0;

  @override
  final List<_PanelLog> panelLogs;

  @override
  int gatewayLogLines = 0;

  @override
  int plantIngestLogLines = 0;

  _PanelLog panel(int index) => panelLogs[index];
}

final class _PanelLog implements SoakPanelLogView {
  _PanelLog(this.index);

  @override
  final int index;

  @override
  String get name => 'panel-$index';

  @override
  bool established = true;

  @override
  int complaints = 0;

  // One by default, so the arms that are about rates are not also about the
  // anti-vacuity gate. The cases that are about the gate set it to zero.
  @override
  int reestablishments = 1;
}

/// The driver, proved at seconds scale.
///
/// **Everything here runs in tens of seconds and that is a design constraint,
/// not a shortcut.** A ten-to-twenty-second timeline is enough to prove
/// composition, playback, ticking, the control's isolation and teardown — and
/// it keeps the RED loop usable. The properties that need thirty-five minutes
/// are `soak_test.dart`'s and 11-07's; a driver case that took half an hour is
/// a case nobody would run twice, and the driver is the thing every later plan
/// builds on.
@Tags(['soak'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

import '../support/gate_b_fixture.dart' show untilSocketsSettle;
import '../support/soak/checkers/terminal_state.dart';
import '../support/soak/invariant.dart';
import '../support/soak/soak_driver.dart';
import '../support/soak/soak_event.dart';
import '../support/soak/soak_observables.dart';
import '../support/soak/soak_timeline.dart';

/// One specimen of every arm of the sealed type, keyed by its kind.
///
/// **Written out here, in the test file, and audited against
/// [SoakEventKinds.all].** 11-01's rule — *counts written down in the test
/// file, never read off the list they audit* — applied to a vocabulary rather
/// than a count. A fifteenth arm added to `soak_event.dart` and to
/// `SoakEventKinds.all` is missing from this map, and the audit below fails by
/// name rather than the coverage arm passing over an arm nobody exercised.
Map<String, SoakEvent> _specimens() => <String, SoakEvent>{
      SoakEventKinds.upstreamLinkDown: const UpstreamLinkDown('ST201'),
      SoakEventKinds.upstreamLinkUp: const UpstreamLinkUp('ST201'),
      SoakEventKinds.upstreamEpochBump: const UpstreamEpochBump('ST301'),
      SoakEventKinds.upstreamMassDegrade: const UpstreamMassDegrade('BAADER'),
      SoakEventKinds.upstreamSlowResolve:
          const UpstreamSlowResolve('ST101', Duration(milliseconds: 40)),
      SoakEventKinds.gatewayRestart: const GatewayRestart(),
      SoakEventKinds.tokenRevocation: const TokenRevocation('panel-3'),
      SoakEventKinds.tokenRestore: const TokenRestore('panel-3'),
      SoakEventKinds.keymappingReload: const KeymappingReload(),
      SoakEventKinds.panelSubscribe:
          PanelSubscribe('panel-1', const <String>['ST101.CN01.MOT01.setpoint']),
      SoakEventKinds.panelUnsubscribe: PanelUnsubscribe(
          'panel-1', const <String>['ST101.CN01.MOT01.setpoint']),
      SoakEventKinds.panelWrite:
          const PanelWrite('panel-2', 'ST201.CN01.MOT01.setpoint', 7),
      SoakEventKinds.panelQuery:
          const PanelQuery('panel-2', 'ST201.CN01.MOT01.setpoint',
              Duration(minutes: 5)),
      SoakEventKinds.plantMutate:
          const PlantMutate('ST301.CN01.MOT01.setpoint', 4242),
    };

/// A timeline this file builds by hand, so a case can put one specific entry in
/// front of the driver instead of hoping a seed produces one.
///
/// Hand-built rather than generated for the reason `schedule_test.dart` gives
/// for its own fixtures: a case about *playback* should not also be a case
/// about what the generator happened to draw, and a case that waits for seed 11
/// to produce a `gatewayRestart` is a case whose failure message is about the
/// wrong thing.
SoakTimeline _handTimeline(
  List<SoakTimelineEntry> entries, {
  required Duration duration,
  int seed = 11,
  List<String> panels = const <String>['panel-1', 'panel-2', 'panel-3', 'panel-4'],
  List<StableWindow> stableWindows = const <StableWindow>[],
}) =>
    SoakTimeline(
      seed: seed,
      duration: duration,
      link: const <ScheduledFault>[],
      events: const <ScheduledSoakEvent>[],
      quietClears: const <ScheduledFault>[],
      merged: entries,
      stableWindows: stableWindows,
      panels: panels,
      aliases: soakAliases,
    );

SoakTimelineEntry _link(Duration at, FaultMutation mutation, {int index = 0}) =>
    SoakTimelineEntry(
      offset: at,
      streamIndex: SoakStreams.link,
      indexWithinStream: index,
      payload: mutation,
    );

SoakTimelineEntry _event(Duration at, SoakEvent event, {int index = 0}) =>
    SoakTimelineEntry(
      offset: at,
      streamIndex: SoakStreams.event,
      indexWithinStream: index,
      payload: event,
    );

/// A journal directory this case owns and deletes.
String _journalDir() {
  final dir = Directory.systemTemp.createTempSync('relay-soak-driver-');
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


/// Builds a driver against a temp journal, and disposes it however the case
/// ends — including when it ends by throwing, which is when a leaked gateway
/// hurts the *next* case rather than this one.
SoakDriver _driver({
  required Duration duration,
  SoakTimeline? timeline,
  int seed = 11,
  int herdSize = 5,
  Duration? populationFloorGraceOverride,
  List<SoakCheckerRegistration> checkers = const <SoakCheckerRegistration>[],
}) {
  final driver = SoakDriver(
    seed: seed,
    duration: duration,
    herdSize: herdSize,
    timeline: timeline,
    journalPath: _journalDir(),
    checkers: checkers,
    populationFloorGrace: populationFloorGraceOverride,
    environment: const <String, String>{},
  );
  addTearDown(driver.dispose);
  return driver;
}

void main() {
  group('the herd', () {
    test('five panels by default, and RELAY_HERD_N overrides it', () {
      expect(soakHerdSize(const <String, String>{}), defaultSoakHerdSize);
      expect(soakHerdSize(const <String, String>{'RELAY_HERD_N': ''}),
          defaultSoakHerdSize,
          reason: 'an empty variable is an unset one: a CI matrix that writes '
              'the name with no value must not stand up a herd of zero');
      expect(soakHerdSize(const <String, String>{'RELAY_HERD_N': '9'}), 9);
    });

    test('a herd too small to have a control is refused, and says why', () {
      expect(() => soakHerdSize(const <String, String>{'RELAY_HERD_N': '2'}),
          throwsArgumentError,
          reason: 'two panels is one control and one stormed panel, which '
              'cannot show a herd effect at all');
      expect(() => soakHerdSize(const <String, String>{'RELAY_HERD_N': 'lots'}),
          throwsArgumentError);
    });

    test('the storm is aimed at every panel except the control', () {
      final driver =
          _driver(duration: const Duration(seconds: 10), herdSize: 5);
      expect(driver.controlPanel, 'panel-0');
      expect(driver.stormPanels,
          <String>['panel-1', 'panel-2', 'panel-3', 'panel-4']);
      expect(driver.stormPanels, isNot(contains(driver.controlPanel)),
          reason: 'this list is what buildTimeline is given, and it is the '
              'only reason a generated storm cannot name the control');
    });

    test('each stormed panel carries its own mode, and the control carries '
        'none', () {
      final driver =
          _driver(duration: const Duration(seconds: 10), herdSize: 5);
      final assigned = <String, int>{
        for (final mode in <String>['flap', 'latency', 'throttle', 'blackhole'])
          mode: driver.panelForMode(mode),
      };
      expect(assigned.values, everyElement(isNot(soakControlPanelIndex)),
          reason: 'a mode routed to panel 0 is a storm reaching the control');
      expect(assigned.values.toSet(), hasLength(4),
          reason: 'the four arming modes of ScenarioWeights.soak land on four '
              'different panels, so no stormed panel is quiet by accident');
    });
  });

  group('refusing a storm that can reach the control', () {
    test('a timeline entry naming the control is refused at start, and the '
        'message names the entry', () async {
      final driver = _driver(
        duration: const Duration(seconds: 10),
        timeline: _handTimeline(
          <SoakTimelineEntry>[
            _event(const Duration(seconds: 1),
                const PanelWrite('panel-0', 'ST101.CN01.MOT01.setpoint', 1)),
          ],
          duration: const Duration(seconds: 10),
        ),
      );
      await expectLater(
        driver.start(),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains('panel-0'), contains('control')))),
        reason: 'a control panel the storm can reach is not a control, and '
            'every invariant would still pass — silently measuring nothing',
      );
    });

    test('the generated timeline never names the control, because it is never '
        'given it', () {
      final driver = _driver(duration: const Duration(minutes: 35));
      final storm = buildTimeline(
        seed: driver.seed,
        duration: driver.duration,
        panels: driver.stormPanels,
        aliases: soakAliases,
      );
      final naming = <String>[
        for (final entry in storm.merged)
          if (entry.payload.toString().contains(driver.controlPanel))
            entry.toString(),
      ];
      expect(naming, isEmpty,
          reason: 'over a full 35-minute storm at the lane seed, not one of '
              '${storm.merged.length} entries may name ${driver.controlPanel}');
    });
  });

  group('the exhaustive apply', () {
    test('the specimen map is the sealed type\'s own list, arm for arm', () {
      expect(_specimens().keys.toSet(), SoakEventKinds.all.toSet(),
          reason: 'a fifteenth arm on the sealed type fails here rather than '
              'passing silently through a coverage arm that never saw it');
      for (final entry in _specimens().entries) {
        expect(entry.value.kind, entry.key,
            reason: 'the specimen filed under ${entry.key} reports itself as '
                '${entry.value.kind}');
      }
    });

    test('every arm pulls a distinct, named lever against a live pipe',
        () async {
      final driver = _driver(
        duration: const Duration(seconds: 20),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 20)),
      );
      await driver.start();

      final levers = <String, String>{};
      for (final entry in _specimens().entries) {
        final outcome = await driver.apply(entry.value);
        expect(outcome.kind, entry.key);
        levers[entry.key] = outcome.lever;
      }

      expect(levers, hasLength(SoakEventKinds.all.length));
      expect(levers.values.toSet(), hasLength(SoakEventKinds.all.length),
          reason: 'fourteen arms, fourteen distinct levers. A switch collapsed '
              'into one default: arm still compiles and still handles every '
              'event — what it cannot do is name fourteen different '
              'mechanisms, which is why this case exists in ADDITION to the '
              'sealed type rather than instead of it. Got: $levers');
    });

    test('a lever that fires into nothing is reported, not counted as applied',
        () async {
      final driver = _driver(
        duration: const Duration(seconds: 20),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 20)),
      );
      await driver.start();

      final first = await driver.apply(const UpstreamLinkDown('ST101'));
      expect(first.fired, isTrue);

      final second = await driver.apply(const UpstreamLinkDown('ST101'));
      expect(second.fired, isFalse,
          reason: 'disconnectUpstream returns early on a link already down '
              '(fake_upstream_link.dart:397), so this event fires into '
              'nothing and silently narrows the storm — repro.log says it was '
              'planned, events.jsonl says it was applied, and neither says it '
              'did nothing');
      expect(second.note, isNotNull);
      expect(driver.fizzled, isNotEmpty);
      expect(driver.fizzled.first, contains('ST101'));
    });
  });

  // ------------------------------------------------------- the epoch exemption
  //
  // `epochBumpedAliases` is the ONE input to `DivergenceCause.epochChange`
  // (`eventual_resync.dart:484-488`), and `epochChange` is the ONE cause the
  // keyframe verdict subtracts (`divergence_ledger.dart:413-420`). A
  // divergence re-attributed to it leaves `countOf(unattributed)` AND the
  // residue sum in the same step — both terms of `keyframesNotNeeded` — so
  // whatever this set says is the milestone's headline decision number.
  //
  // Which makes its LIFETIME the property, not its contents. The condition an
  // epoch bump excuses is a re-browse; the set is a plain `Set<String>`, and
  // the exemption must not outlive the settling the generator declares for the
  // kind.
  group('the epoch exemption', () {
    test('a bump exempts its alias for the settling span and not for the rest '
        'of the run', () async {
      final driver = _driver(
        duration: const Duration(seconds: 30),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 30)),
      );
      await driver.start();

      final span = SoakEventSchedule.recoverySpanOf(
          SoakEventKinds.upstreamEpochBump);

      final outcome = await driver.apply(const UpstreamEpochBump('ST101'));
      expect(outcome.fired, isTrue);
      expect(driver.epochBumpedAliases, <String>{'ST101'},
          reason: 'the bump happened, so the alias is exempt while the '
              're-browse it excuses is in flight');

      await Future<void>.delayed(span + const Duration(milliseconds: 750));

      expect(driver.epochBumpedAliases, isEmpty,
          reason: 'the bump is a TRANSIENT condition and the exemption it '
              'buys must be transient too. Left permanent, every subsequent '
              'non-good-quality divergence on ST101 is attributed epochChange '
              'for the rest of the run — subtracted from residue AND absent '
              'from countOf(unattributed), which is both halves of the '
              'keyframe verdict. The storm draws this lever ~4 times in '
              'thirty-five minutes, so two draws on distinct aliases exempt '
              'half the plant');
    });

    test('a second bump extends the exemption instead of the first recovery '
        'cutting it short', () async {
      // The defect the obvious fix imports. One timer per bump, with no
      // bookkeeping, means bump A's recovery fires while bump B is still
      // armed and clears an exemption B is entitled to — `upstreamSlowResolve`
      // has exactly this shape today (M-15). Avoided here by construction
      // rather than reproduced one file over.
      final driver = _driver(
        duration: const Duration(seconds: 30),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 30)),
      );
      await driver.start();

      final span = SoakEventSchedule.recoverySpanOf(
          SoakEventKinds.upstreamEpochBump);

      await driver.apply(const UpstreamEpochBump('ST101'));
      await Future<void>.delayed(const Duration(seconds: 2));
      await driver.apply(const UpstreamEpochBump('ST101'));

      // Past the FIRST bump's span, inside the second's.
      await Future<void>.delayed(span - const Duration(seconds: 1));
      expect(driver.epochBumpedAliases, <String>{'ST101'},
          reason: 'the first bump\'s recovery must not clear an exemption the '
              'second bump is still entitled to');

      // Past the second's.
      await Future<void>.delayed(const Duration(milliseconds: 1750));
      expect(driver.epochBumpedAliases, isEmpty,
          reason: 'and the second bump\'s own span still ends it');
    });

    test('one alias\'s bump exempts that alias and nobody else', () async {
      final driver = _driver(
        duration: const Duration(seconds: 30),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 30)),
      );
      await driver.start();

      await driver.apply(const UpstreamEpochBump('ST101'));
      expect(driver.epochBumpedAliases, hasLength(1),
          reason: 'ten of the forty plant keys ride on one alias, so a set '
              'that widened by accident would exempt a quarter of the plant');
      expect(driver.epochBumpedAliases, isNot(contains('BAADER')));
    });
  });

  // ------------------------------------------- levers that must not overclaim
  //
  // `SoakApplyOutcome.fizzled` exists because "a storm that quietly narrows
  // itself is the failure mode both halves of the artifact hide on their own"
  // (`soak_event.dart:60-66`). A lever that reports `fired` for something it
  // did not do is that failure with a green tick on it.
  group('levers that must not report firing into nothing', () {
    test('a mass degrade on an ALREADY DOWN alias fizzles', () async {
      // The generator guards `upstreamEpochBump` against a down alias
      // (`SoakExclusivityRules.bumpOnDownAlias`) and `upstreamLinkDown`
      // against a second down. It has no such rule for `upstreamMassDegrade`,
      // and the driver's arm returned `fired` unconditionally — while having
      // read `statusNotifications` before and after, so it held the evidence
      // and threw it away.
      //
      // Real shape: `UpstreamLinkDown(ST301)` at +03:24 with its paired
      // `UpstreamLinkUp` at +03:48, and a mass-degrade draw landing on ST301
      // at +03:35. Every key it carries is already bad-quality from
      // `disconnectUpstream`'s own `applyLinkLoss`, `announceLinkState`
      // re-announces a state nothing changed, and `events.jsonl` records
      // `"fired": true` for a degrade the run did not deliver.
      final driver = _driver(
        duration: const Duration(seconds: 20),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 20)),
      );
      await driver.start();

      final healthy = await driver.apply(const UpstreamMassDegrade('ST101'));
      expect(healthy.fired, isTrue,
          reason: 'the negative half: on a live link the lever really does '
              'degrade, and a fizzle here would mean the arm had been made '
              'blind rather than honest');

      expect((await driver.apply(const UpstreamLinkDown('ST301'))).fired,
          isTrue);
      final onADeadLink =
          await driver.apply(const UpstreamMassDegrade('ST301'));

      expect(onADeadLink.fired, isFalse,
          reason: 'ST301 is already disconnected and every key it carries is '
              'already bad-quality, so this degraded nothing. Counting it in '
              'the verdict block\'s levers line is the storm narrowing itself '
              'while the artifact says it widened');
      expect(onADeadLink.note, isNotNull);
      expect(driver.fizzled.last, contains('ST301'));
    });

    test('a subscribe after a REDIAL opens against the new client, and does '
        'not report the dead one as already held', () async {
      // `PanelSubscribe` files its handle as `panel|key` and nothing clears it
      // when `GateBFixture.redial` replaces the panel's `RemoteStateMan`
      // outright. The driver is careful about this everywhere else —
      // `panelViews`, `panelResyncViews` and `panelLogs` are all rebuilt per
      // call with a doc explaining exactly this hazard — and `_subscriptions`
      // was missed.
      //
      // The consequence is the same class as the case above: the second draw
      // finds the handle present, skips it, and reports `fizzled … already
      // held every one of` — about a subscription on an object disposed
      // minutes earlier. The arm the `SoakApplyOutcome` type exists to make
      // visible reports the OPPOSITE of what happened.
      const key = 'ST101.CN01.MOT01.setpoint';
      final driver = _driver(
        duration: const Duration(seconds: 30),
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: const Duration(seconds: 30)),
      );
      await driver.start();

      expect(
          (await driver.apply(PanelSubscribe('panel-3', const <String>[key])))
              .fired,
          isTrue);

      // The pair the timeline always draws together, and the only thing in the
      // storm that replaces a client.
      expect((await driver.apply(const TokenRevocation('panel-3'))).fired,
          isTrue);
      expect(
          (await driver.apply(const TokenRestore('panel-3'))).fired, isTrue);
      await Future<void>.delayed(const Duration(seconds: 3));

      final again =
          await driver.apply(PanelSubscribe('panel-3', const <String>[key]));
      expect(again.fired, isTrue,
          reason: 'the new client holds nothing of the sort — the old handle '
              'names a subscription on a disposed object. Reporting "already '
              'held" here is the storm narrowing itself for a reason that is '
              'not true');
    });
  });

  group('a short run against the composed pipe', () {
    test('the pipe stands up, the storm plays, and every planned entry is '
        'applied', () async {
      const duration = Duration(seconds: 12);
      final driver = _driver(
        duration: duration,
        timeline: _handTimeline(
          <SoakTimelineEntry>[
            _link(const Duration(seconds: 2),
                const LatencyMutation(latency: Duration(milliseconds: 30))),
            _event(const Duration(seconds: 3),
                const PlantMutate('ST101.CN01.MOT01.setpoint', 77),
                index: 0),
            _event(const Duration(seconds: 5), const KeymappingReload(),
                index: 1),
            _event(const Duration(seconds: 7),
                const PanelWrite('panel-2', 'ST201.CN01.MOT01.setpoint', 9),
                index: 2),
            _link(const Duration(seconds: 9), const LatencyMutation.off(),
                index: 1),
          ],
          duration: duration,
        ),
      );

      await driver.run();

      expect(driver.applied, hasLength(driver.timeline.merged.length));
      expect(driver.neverReached, isEmpty,
          reason: 'planned != applied is the failure a soak cannot otherwise '
              'see:\n${driver.divergenceReport}');
      expect(driver.fizzled, isEmpty,
          reason: 'no lever in this timeline fires into nothing');
      expect(File('${driver.journalPath}/repro.log').existsSync(), isTrue);
      expect(File('${driver.journalPath}/config.json').existsSync(), isTrue);
      expect(driver.journal.eventCount, driver.applied.length);
      expect(driver.journal.checkpointCount, greaterThan(0),
          reason: 'a run with no checkpoint sampled nothing at all');
    });

    test('the control is untouched by the storm and stays ready, while a '
        'stormed panel does not', () async {
      const duration = Duration(seconds: 16);
      final driver = _driver(
        duration: duration,
        timeline: _handTimeline(
          <SoakTimelineEntry>[
            // flap -> panel 1, blackhole -> panel 4. Neither can reach panel 0.
            _link(
                const Duration(seconds: 2),
                const FlapMutation(
                    up: Duration(milliseconds: 700),
                    down: Duration(milliseconds: 700))),
            _link(const Duration(seconds: 2),
                const BlackholeMutation(enabled: true),
                index: 1),
            _link(const Duration(seconds: 13), const FlapMutation.off(),
                index: 2),
            _link(const Duration(seconds: 13),
                const BlackholeMutation(enabled: false),
                index: 3),
          ],
          duration: duration,
        ),
      );

      await driver.run();

      expect(driver.controlHealth.mutationsApplied, 0,
          reason: 'the storm applied a link mutation to the control\'s proxy. '
              'A control panel the storm can reach is not a control — this is '
              'the pre-07-08b bug class, a gateway punishing healthy panels, '
              'and an all-faulted population cannot see it');
      expect(driver.controlHealth.readyDips, 0,
          reason: 'the control lost its link ${driver.controlHealth.readyDips} '
              'times during a storm aimed at four other panels. Control '
              'health: ${driver.controlHealth}');
      expect(driver.controlHealth.staleViewSamples, 0,
          reason: 'the control\'s whole view went stale during a storm it was '
              'not in. Control health: ${driver.controlHealth}');
      expect(driver.controlHealth.samples, greaterThan(0),
          reason: 'a control with no samples proves nothing: the three '
              'assertions above would all pass on a panel nobody looked at');

      final stormed = <SoakPanelHealth>[
        for (final entry in driver.health.entries)
          if (entry.key != soakControlPanelIndex) entry.value,
      ];
      expect(stormed.map((one) => one.mutationsApplied).reduce((a, b) => a + b),
          greaterThan(0),
          reason: 'the storm reached nobody at all, so the control\'s health '
              'says nothing: ${stormed.join('; ')}');
      expect(stormed.any((one) => one.readyDips > 0 || one.notReadySamples > 0),
          isTrue,
          reason: 'a flap and a blackhole for eleven seconds and not one '
              'stormed panel noticed: ${stormed.join('; ')}');
    });

    test('the population floor records a violation with its offset, and the '
        'run continues', () async {
      const duration = Duration(seconds: 20);
      final driver = _driver(
        duration: duration,
        // Two seconds rather than the shipping seventy-five: the constant is
        // sized for a token restore's own sixty-second window, and a case that
        // waited it out would be a seventy-five-second unit test. What is
        // under test is that the floor trips, names its offset and does not
        // abort — not the value of the grace.
        populationFloorGraceOverride: const Duration(seconds: 2),
        timeline: _handTimeline(
          <SoakTimelineEntry>[
            // Two revocations with no restores: the paired recovery the
            // generator would have emitted is deliberately absent, which is
            // exactly the shape of a monotonic cull.
            _event(const Duration(seconds: 2),
                const TokenRevocation('panel-1')),
            _event(const Duration(seconds: 3),
                const TokenRevocation('panel-2'),
                index: 1),
            _event(const Duration(seconds: 18),
                const PlantMutate('ST101.CN01.MOT01.setpoint', 5),
                index: 2),
          ],
          duration: duration,
        ),
      );

      await driver.run();

      final floorBreaches = <SoakViolation>[
        for (final violation in driver.violations)
          if (violation.checker == 'population') violation,
      ];
      expect(floorBreaches, isNotEmpty,
          reason: 'two panels revoked with no restore leaves three of five '
              'connected, under a floor of four, for the rest of the run. '
              'Violations recorded: ${driver.violations}');
      expect(floorBreaches.first.monotonic, greaterThan(Duration.zero));
      expect(floorBreaches.first.toString(), contains('+00:'),
          reason: 'a floor breach with no offset is a breach nobody can place '
              'in the timeline');
      expect(driver.applied, hasLength(3),
          reason: 'the run continued to its last entry: a breach is a recorded '
              'violation, never an abort');
      expect(driver.worstBelowFloor, greaterThan(const Duration(seconds: 2)));
    });

    test('teardown settles every socket and closes the journal', () async {
      final baseline = openSocketCount();
      const duration = Duration(seconds: 8);
      final driver = _driver(
        duration: duration,
        timeline: _handTimeline(
          <SoakTimelineEntry>[
            _event(const Duration(seconds: 2),
                const PlantMutate('ST101.CN01.MOT01.setpoint', 3)),
          ],
          duration: duration,
        ),
      );

      await driver.run();
      await driver.dispose();

      final settled = await untilSocketsSettle(baseline);
      expect(settled, lessThanOrEqualTo(baseline),
          reason: 'the soak opened a gateway, five proxies and five panels and '
              'left ${settled - baseline} descriptors behind');
      expect(driver.journal.retainedInventory['openSinks'], 2,
          reason: 'the inventory still declares both sinks; what the case '
              'asserts is that close() ran, below');
      expect(
          File('${driver.journalPath}/metrics.jsonl').readAsStringSync(),
          isNotEmpty,
          reason: 'a journal closed before its buffers flushed leaves an '
              'empty artifact, which is the one thing a failed run has');
    }, skip: canCountOpenSockets ? null : openSocketCountSkipReason);
  });

  group('a write the redial orphaned', () {
    test('is not reported as silently lost, because the retired client still '
        'holds it', () async {
      // **The instrument defect behind 11-07's four `terminalStateWrites`
      // violations, at seconds scale.** The 35-minute arm at seed 11 reported
      // writes #103, #108, #110 and #400 as "reached a socket and is in
      // NEITHER the terminal map nor the client's unresolved set". All four
      // were on panel-2 and panel-4 — the only two panels the run ever
      // redialed — and all four were issued before their panel's redial.
      //
      // Nothing lost them. Each is still in the `_unresolved` set of the
      // `RemoteStateMan` that `GateBFixture.redial` replaced: `dispose()` does
      // not clear that set, so a retired client still answers
      // `debugUnresolvedCmds` with what was in flight. What the run-end arm
      // read was `SoakDriver.unresolvedCmds`, a union over the CURRENT clients
      // only — so the write was invisible from both sides for a reason that
      // was about the harness and not about the pipe.
      //
      // This case is the whole mechanism in three steps and thirty seconds:
      // take the alias down so the gateway can only answer `unknown`, write,
      // then replace the client under it.
      const key = 'ST301.CN01.MOT01.setpoint';
      const duration = Duration(seconds: 30);
      final driver = _driver(
        duration: duration,
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: duration),
      );
      await driver.start();

      // The write has to cross while its own alias is down. That is what makes
      // the gateway answer a non-established outcome, and an `unknown` that
      // was dispatched is the one verdict the client KEEPS — re-queryable, by
      // design, for the next entry to `ready`.
      expect(
          (await driver.apply(const UpstreamLinkDown('ST301'))).fired, isTrue);
      await driver.issueWrite(
          panelIndex: 3, key: key, value: 4321, probe: false);

      final cmd = driver.writeRecords
          .lastWhere((record) => record.stage == SoakWriteStage.issued)
          .cmd;

      // **The precondition, asserted rather than assumed.** If the gateway
      // answered something established here, this case would pass for the
      // wrong reason — there would be no orphan to lose, and the arm below
      // would be judging nothing. Failing here says the setup is wrong;
      // failing below says the harness is.
      expect(driver.unresolvedCmds, contains(cmd),
          reason: 'the write was supposed to come back `unknown` and stay '
              're-queryable on panel-3, which is the only state a redial can '
              'orphan. It is not in the unresolved set, so this case is no '
              'longer exercising what it was written for');

      // The pair the timeline always draws together, and the only thing in the
      // storm that replaces a client (`GateBFixture.redial`).
      expect((await driver.apply(const TokenRevocation('panel-3'))).fired,
          isTrue);
      expect(
          (await driver.apply(const TokenRestore('panel-3'))).fired, isTrue);
      await Future<void>.delayed(const Duration(seconds: 3));

      // Declared under `distributionArmFloor` on purpose: this case is about
      // the run-end placement arm, and a thirty-second run has no business
      // being asked whether the storm produced all three outcomes.
      final checker = TerminalStateChecker(driver, declared: duration);
      checker.finish();

      final lost = checker.violations
          .where((one) => one.toString().contains('in NEITHER'))
          .toList();
      expect(lost, isEmpty,
          reason: 'the cmd is still in the retired client\'s unresolved set — '
              'the panel restarted, it did not lose the write. Reporting it as '
              'silently lost is the harness asserting continuity across the '
              'one event it models as a discontinuity, and it is what made the '
              '35-minute arm red on a pipe that was behaving:\n'
              '${lost.join('\n')}');
    });
  });

  group('the write probe honours the quiet windows', () {
    test('a probe due inside a stable window is withheld, and the probe '
        'resumes after the window closes', () async {
      // **The CI finding this pins (2026-09-09, seed 11, ubuntu runner):**
      // `ST201.CN02.MOT01.setpoint in window 0 (unattributed)` on the
      // never-faulted control panel. The probe wrote `900015` to a real plant
      // key at +32 s — inside the [22.5..32.5) window — and the plant
      // genuinely published that value to every panel until the next 250 ms
      // sweep superseded it. `plantTruthFor` answers the sweep counter for a
      // non-overridden key, so a panel honestly rendering the value the plant
      // actually published was judged diverged; whether the window's LAST
      // sample lands inside that ~250 ms overlay is timer-phase roulette,
      // which is why the lane was green on a fast machine and red on a loaded
      // runner (all five of the run's divergences healed exactly 1 ms after
      // their window — a lost push cannot heal in 1 ms; a write overlay
      // expiring at the next sweep always does).
      //
      // The rule already exists everywhere else: the timeline WITHHOLDS link
      // entries inside quiet windows ("withholding is what makes the window
      // quiet"), and the event schedule suppresses draws — `PanelWrite`
      // included — that would reach into one. The probe is the one
      // plant-moving actor outside the timeline, so it must carry the same
      // discipline itself.
      const duration = Duration(seconds: 16);
      const window = StableWindow(Duration(seconds: 3), Duration(seconds: 11));
      final driver = _driver(
        duration: duration,
        timeline: _handTimeline(const <SoakTimelineEntry>[],
            duration: duration,
            stableWindows: const <StableWindow>[window]),
      );
      // The whole declared duration, exactly as `soak_test.dart` runs it —
      // `at` on a write record is the PLAY clock, which only advances inside
      // play(), so a case that started the tickers without playing would be
      // asserting about records pinned at +00:00.000.
      await driver.run();

      // Probes fall due at 2, 4, 6, 8, 10, 12, 14 s of a 16 s arm; the
      // window covers [3..11). Assert direction, not exact counts — a loaded
      // machine slips a timer, and the property is WHERE the probe fired,
      // never how often.
      bool resumed() => driver.writeRecords.any((record) =>
          record.probe &&
          record.stage == SoakWriteStage.issued &&
          record.at >= window.end);

      final issuedInside = driver.writeRecords
          .where((record) =>
              record.probe &&
              record.stage == SoakWriteStage.issued &&
              window.contains(record.at))
          .toList();
      expect(issuedInside, isEmpty,
          reason: 'the probe fired into a stable window. An applied write '
              'puts a real, plant-published value on a key for up to one '
              'sweep period, and plant truth for a non-overridden key is the '
              'sweep counter — so every honest panel reads as diverged for '
              'the life of the overlay, and invariant 3\'s window-end '
              'judgement turns into timer-phase roulette. The storm\'s own '
              'levers and event draws are withheld inside windows for exactly '
              'this reason:\n${issuedInside.join('\n')}');
      expect(driver.probeWritesWithheld, greaterThanOrEqualTo(1),
          reason: 'four probes fell due inside an eight-second window and '
              'none was counted as withheld — the probe is not recording the '
              'fire it held, so the verdict\'s writes line would claim a '
              'cadence the run did not keep');
      expect(resumed(), isTrue,
          reason: 'no probe was issued after the window closed — withholding '
              'must hold fire, not stop the probe: invariant 2\'s write '
              'coverage outside the windows is the reason the probe exists');
    });
  });
}

/// The storm's other half, and the proof that one seed still means one storm.
///
/// ROADMAP criterion 3 — *"re-running with the same seed reproduces the
/// identical fault schedule, proven by a test comparing two runs' event
/// logs"* — is **already true for the link half**, and Phase 2 proved it:
/// `schedule_test.dart:42` (same seed, identical timeline, identical repro
/// log) and `:233` (two playbacks of one seed apply the same sequence). This
/// file does not rebuild any of that. It extends the same proof to the
/// **merged** timeline the soak adds, and pins the one class of change that
/// could quietly break it.
///
/// Everything here is pure computation — no sockets, no timers, no clock —
/// which is why a thirty-five-minute storm is generated and asserted in
/// milliseconds without being run. That is the whole argument
/// `scenario_schedule.dart`'s library doc makes, inherited rather than
/// restated.
@TestOn('vm')
@Tags(['soak'])
library;

import 'package:test/test.dart';
import 'package:tfc_stateman_contract/faults.dart';

import '../support/soak/soak_event.dart';
import '../support/soak/soak_timeline.dart';

/// The full arm's duration, and the one every printed number is quoted at.
const Duration _fullSoak = Duration(minutes: 35);

/// §7.8's own thirty minutes, for the density arithmetic the research quotes.
const Duration _thirtyMinutes = Duration(minutes: 30);

/// How many seeds each exclusivity sweep covers.
///
/// The shape of `schedule_test.dart:118`: a rule with a narrow hole is more
/// likely to fall into it over a hundred seeds than over one, and the sweep is
/// pure computation, so the cost of the extra seeds is a second.
const int _sweepSeeds = 100;

/// The sweep runs at a deliberately dense band, and that is not a shortcut.
///
/// `schedule_test.dart:118` sweeps with `ScenarioWeights.everything` rather
/// than the default profile for a stated reason — *"a safety rule only
/// exercised by the profile nobody runs is a safety rule nobody has tested"*.
/// The same problem arrives here through the gap band instead of the weights:
/// at the shipping 10–40 s band a gateway restart happens about four times in
/// thirty-five minutes, so two of them landing inside fifteen seconds of each
/// other is rare enough that rule 1 would almost never be asked anything. At
/// 1–3 s every rule is asked hundreds of times per sweep, and the per-rule
/// skip counters below prove it rather than assuming it.
const Duration _denseMinGap = Duration(seconds: 1);
const Duration _denseMaxGap = Duration(seconds: 3);
const Duration _sweepDuration = Duration(minutes: 10);

/// A panel population the shape 11-03 will compose: five, and the storm may
/// target four of them.
const List<String> _panels = <String>[
  'panel-1',
  'panel-2',
  'panel-3',
  'panel-4',
];

/// The plant's aliases, in the shape the SVN topology actually has.
const List<String> _aliases = <String>['ST101', 'ST201', 'ST301', 'BAADER'];

/// The salt, written down here rather than read off the constant it audits.
///
/// The second copy is the whole point — `gate_manifest_test.dart:44-50`'s
/// argument, inherited through 11-01: a sweep that derives both sides of its
/// comparison from one source asserts nothing.
const int _declaredEventStreamSalt = 0x50AC;

/// Seed 11's storm, as it stood when this line was written.
///
/// Seed 11 is the lane's fixed default (11-CONTEXT ruling 4), so this is the
/// storm whose `(seed, schedule log)` pairs end up in issues. See the case for
/// what to do when it fails.
const int _seed11EntryCount = 96;
const List<String> _seed11Head = <String>[
  '[00:23.829] keymapping reload',
  '[01:01.386] panel-3 query BAADER.CN02.run over 1m',
  '[01:34.367] panel-4 query ST101.CN03.run over 1m',
  '[01:54.769] panel-4 query BAADER.CN01.run over 5m',
  '[02:22.987] panel-1 query ST301.CN02.run over 15m',
];
const String _seed11Tail =
    '[34:51.867] panel-3 subscribe ST201.CN03.run+ST301.CN02.run';

/// The lane's short arm, which runs on every push (11-CONTEXT ruling 2).
const Duration _shortSoak = Duration(seconds: 90);

/// Where the two synthetic streams collide, for the total-order case.
const Duration _collisionOffset = Duration(seconds: 30);

/// How many differently-sized merges the total-order case performs.
const int _mergeTrials = 100;

/// How many filler entries each synthetic stream carries.
///
/// Well past 32, which is where `package:collection`'s and the SDK's sorts
/// stop using insertion sort and start using the unstable quicksort: a
/// twelve-entry fixture would keep its order under an offset-only comparator
/// too, and the case would be decoration.
const int _fillerEntries = 200;

/// A synthetic link stream with exactly one entry at [_collisionOffset].
List<ScheduledFault> _fillerLink() => <ScheduledFault>[
      for (var i = 0; i < _fillerEntries; i++)
        ScheduledFault(Duration(milliseconds: 137 * i),
            i.isEven ? const BlackholeMutation() : const FlapMutation.off()),
      const ScheduledFault(_collisionOffset, ThrottleMutation(4096)),
    ]..sort((a, b) => a.offset.compareTo(b.offset));

/// A synthetic event stream with exactly one entry at [_collisionOffset].
List<ScheduledSoakEvent> _fillerEvents() => <ScheduledSoakEvent>[
      for (var i = 0; i < _fillerEntries; i++)
        ScheduledSoakEvent(Duration(milliseconds: 149 * i),
            PlantMutate('ST101.CN01.run', i)),
      const ScheduledSoakEvent(_collisionOffset, GatewayRestart()),
    ]..sort((a, b) => a.offset.compareTo(b.offset));

/// The stream labels of the entries sitting exactly on [_collisionOffset],
/// joined — because `List` has identity equality in Dart, and comparing two
/// freshly-built lists with `==` is a comparison that can never be true. The
/// first run of this case returned 0 of 100 for exactly that reason.
String _orderAtCollision(List<SoakTimelineEntry> merged) => <String>[
      for (final entry in merged)
        if (entry.offset == _collisionOffset)
          SoakStreams.labelOf(entry.streamIndex),
    ].join(',');

SoakTimeline _timeline({required int seed, required Duration duration}) =>
    buildTimeline(
      seed: seed,
      duration: duration,
      panels: _panels,
      aliases: _aliases,
    );

void main() {
  group('SoakEvent — the sealed vocabulary', () {
    test('every arm reports a kind the registry declares, and the registry '
        'declares no kind without an arm', () {
      final built = <SoakEvent>[
        const UpstreamLinkDown('ST101'),
        const UpstreamLinkUp('ST101'),
        const UpstreamEpochBump('ST101'),
        const UpstreamMassDegrade('ST101'),
        const UpstreamSlowResolve('ST101', Duration(milliseconds: 500)),
        const GatewayRestart(),
        const TokenRevocation('panel-1'),
        const TokenRestore('panel-1'),
        const KeymappingReload(),
        PanelSubscribe('panel-1', const <String>['ST101.CN01.run']),
        PanelUnsubscribe('panel-1', const <String>['ST101.CN01.run']),
        const PanelWrite('panel-1', 'ST101.CN01.run', 1),
        const PanelQuery('panel-1', 'ST101.CN01.run', Duration(minutes: 5)),
        const PlantMutate('ST101.CN01.run', 7),
      ];

      expect(built.map((e) => e.kind).toList(), equals(SoakEventKinds.all),
          reason: 'the fourteen arms and the fourteen declared kinds have '
              'drifted apart. The registry is what the weights are validated '
              'against and what the density report is keyed by, so a kind '
              'with no arm weights nothing and an arm with no kind is drawn '
              'by nobody');
      expect(SoakEventKinds.drawable.length + SoakEventKinds.pairedRecoveries.length,
          SoakEventKinds.all.length,
          reason: 'every kind is either drawn or emitted as a recovery; a '
              'kind that is neither can never appear in a storm');
    });

    test('two arms of one shape with different payloads are not equal', () {
      expect(const UpstreamLinkDown('ST101'),
          isNot(equals(const UpstreamLinkDown('ST201'))));
      expect(const PanelWrite('panel-1', 'k', 1),
          isNot(equals(const PanelWrite('panel-1', 'k', 2))));
      expect(PanelSubscribe('panel-1', const <String>['a', 'b']),
          equals(PanelSubscribe('panel-1', const <String>['a', 'b'])),
          reason: 'the merged timeline is compared element by element across '
              'two generations, so an arm carrying a list needs value '
              'equality over that list or criterion 3 compares identities');
      expect(PanelSubscribe('panel-1', const <String>['a', 'b']),
          isNot(equals(PanelSubscribe('panel-1', const <String>['b', 'a']))));
    });

    test('the offset stamp renders exactly as the link half renders it', () {
      // The merged log interleaves both halves. If the two renderings differ
      // by a character the columns stop lining up, and the artifact a human
      // pastes into an issue is the thing that gets harder to read.
      const offset = Duration(minutes: 23, seconds: 7, milliseconds: 412);
      final linkLine =
          const ScheduledFault(offset, BlackholeMutation()).toString();

      expect(linkLine, startsWith('[${formatScheduleStamp(offset)}]'),
          reason: 'formatScheduleStamp and scenario_schedule.dart\'s private '
              '_stamp render the same offset differently: $linkLine');
    });
  });

  group('SoakEventSchedule.generate — the pure part', () {
    test('the same seed produces an identical event list', () {
      final first = SoakEventSchedule.generate(
        seed: 42,
        duration: _fullSoak,
        panels: _panels,
        aliases: _aliases,
      );
      final second = SoakEventSchedule.generate(
        seed: 42,
        duration: _fullSoak,
        panels: _panels,
        aliases: _aliases,
      );

      expect(second, equals(first),
          reason: 'a soak failure is reproduced from its seed alone, so two '
              'generations of one seed that differ mean the repro procedure '
              'does not work — and the event half is the half nobody would '
              'think to check, because Phase 2 already proved the link half');
      expect(second, isNotEmpty,
          reason: 'two empty lists are equal, so this arm would pass over a '
              'generator that produced nothing at all');
    });

    test('neighbouring seeds diverge from event one', () {
      final firsts = <String>{};
      for (var seed = 1; seed <= 20; seed++) {
        final events = SoakEventSchedule.generate(
          seed: seed,
          duration: _fullSoak,
          panels: _panels,
          aliases: _aliases,
        );
        firsts.add(events.first.toString());
      }

      expect(firsts, hasLength(greaterThan(15)),
          reason: 'twenty neighbouring seeds produced ${firsts.length} '
              'distinct first events. SeededScenarioRandom runs splitmix64 '
              'over the seed precisely so that seed n and seed n+1 do not '
              'start alike (scenario_schedule.dart:670-675); a salt applied '
              'without that spreading would undo it');
    });

    test('a 35-minute generation is fast, and the density is printed', () {
      final clock = Stopwatch()..start();
      final report = SoakEventSchedule.generateReport(
        seed: 11,
        duration: _fullSoak,
        panels: _panels,
        aliases: _aliases,
      );
      clock.stop();

      final thirty = SoakEventSchedule.generateReport(
        seed: 11,
        duration: _thirtyMinutes,
        panels: _panels,
        aliases: _aliases,
      );
      final link30 =
          ScenarioSchedule.generate(seed: 11, duration: _thirtyMinutes);

      final perMinute = report.events.length / _fullSoak.inMinutes;
      final buffer = StringBuffer()
        ..writeln('event stream density (seed 11, '
            'band ${SoakEventSchedule.defaultMinGap.inSeconds}'
            '-${SoakEventSchedule.defaultMaxGap.inSeconds}s):')
        ..writeln('  30 min: ${thirty.events.length} events '
            '(${(thirty.events.length / 30).toStringAsFixed(2)}/min) '
            'from ${thirty.draws} draws')
        ..writeln('  30 min link half: ${link30.length} entries '
            '(${(link30.length / 30).toStringAsFixed(2)}/min)')
        ..writeln('  30 min merged:    ${thirty.events.length + link30.length} '
            'entries '
            '(${((thirty.events.length + link30.length) / 30).toStringAsFixed(2)}/min)')
        ..writeln('  35 min: ${report.events.length} events '
            '(${perMinute.toStringAsFixed(2)}/min) from ${report.draws} draws')
        ..writeln('  generated in ${clock.elapsedMilliseconds} ms');
      for (final kind in SoakEventKinds.all) {
        final count = report.events.where((e) => e.event.kind == kind).length;
        buffer.writeln('    ${kind.padRight(21)} $count '
            '(${(count / _fullSoak.inMinutes).toStringAsFixed(2)}/min)');
      }
      buffer.writeln('  suppressed by rule:');
      for (final rule in SoakExclusivityRules.all) {
        buffer.writeln('    ${rule.padRight(21)} ${report.skipsByRule[rule]}');
      }
      // ignore: avoid_print
      print(buffer);

      expect(clock.elapsed, lessThan(const Duration(seconds: 1)),
          reason: 'the whole timeline is generated before the soak starts, so '
              'generation cost must not show up as soak time '
              '(schedule_test.dart:94-96)');
      // 30 minutes at a 10-40 s band is ~72 draws; the paired recoveries add
      // one entry each and the suppressions take some away, so the band is
      // wide on both sides. Far outside it means the cadence drifted.
      expect(thirty.events.length, inInclusiveRange(50, 130),
          reason: '11-RESEARCH §C.3 sizes the event stream at ~72 entries in '
              'thirty minutes against the link half\'s ~327; outside this '
              'band the storm is either a queue or a trickle');
    });

    test('offsets never go backwards', () {
      final events = SoakEventSchedule.generate(
        seed: 99,
        duration: _fullSoak,
        panels: _panels,
        aliases: _aliases,
      );
      var previous = Duration.zero;
      for (final entry in events) {
        expect(entry.offset, greaterThanOrEqualTo(previous),
            reason: 'playback walks the list in order against a single '
                'drift-corrected timer, so an offset that went backwards '
                'would be applied immediately and out of sequence. The paired '
                'recoveries are the risk here: they are drawn ahead of the '
                'events that follow them and have to be flushed in place');
        previous = entry.offset;
      }
      expect(events.last.offset, lessThan(_fullSoak),
          reason: 'an event on the run\'s last microsecond leaves the soak\'s '
              'final assertions running against something nobody scheduled '
              'time to observe');
    });

    test('the generated list is unmodifiable', () {
      final events = SoakEventSchedule.generate(
        seed: 3,
        duration: const Duration(minutes: 2),
        panels: _panels,
        aliases: _aliases,
      );
      expect(() => events.add(events.first), throwsUnsupportedError,
          reason: 'the timeline is the repro log; a caller that could append '
              'to it could make the log disagree with the seed that produced '
              'it');
    });

    test('generation refuses arguments that cannot describe a run', () {
      List<ScheduledSoakEvent> gen({
        Duration duration = const Duration(minutes: 1),
        Duration minGap = SoakEventSchedule.defaultMinGap,
        Duration maxGap = SoakEventSchedule.defaultMaxGap,
        List<String> panels = _panels,
        List<String> aliases = _aliases,
      }) =>
          SoakEventSchedule.generate(
            seed: 1,
            duration: duration,
            minGap: minGap,
            maxGap: maxGap,
            panels: panels,
            aliases: aliases,
          );

      expect(() => gen(duration: Duration.zero), throwsArgumentError);
      expect(() => gen(minGap: Duration.zero), throwsArgumentError);
      expect(
          () => gen(
              minGap: const Duration(seconds: 5),
              maxGap: const Duration(seconds: 1)),
          throwsArgumentError);
      expect(() => gen(panels: const <String>[]), throwsArgumentError,
          reason: 'a storm with no panels to target draws panel events that '
              'name nobody, and every panel invariant then passes vacuously');
      expect(() => gen(aliases: const <String>[]), throwsArgumentError);
    });

    test('weights are checked against the kind registry', () {
      expect(const SoakEventWeights(<String, int>{'plantMutat': 1}).validate,
          throwsArgumentError,
          reason: 'a misspelled kind would silently weight nothing and the '
              'storm would never pull that lever');
      expect(const SoakEventWeights(<String, int>{}).validate,
          throwsArgumentError);
      expect(
          const SoakEventWeights(<String, int>{SoakEventKinds.plantMutate: -1})
              .validate,
          throwsArgumentError);
      expect(SoakEventWeights.soak.validate, returnsNormally);
    });

    test('a paired recovery cannot be weighted, and the refusal says why', () {
      Object? thrown;
      try {
        const SoakEventWeights(<String, int>{SoakEventKinds.tokenRestore: 1})
            .validate();
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ArgumentError>());
      expect(thrown.toString(), contains('paired recovery'),
          reason: 'a storm able to draw a bare TokenRestore could restore a '
              'credential it never revoked, and rule 2 stops being '
              'structural: $thrown');
    });

    test('the salt is the declared one, written down in this file', () {
      // `SeededScenarioRandom`'s own doc states the rule this pin makes
      // mechanical: *"any change to the constants below invalidates every
      // schedule log ever printed"*. Nothing enforced that for the salt — the
      // salt sabotage (11-02 SUMMARY) moves the event stream for 20 of 20
      // seeds and every case in this file still passed, because they all
      // compare two generations of the SAME build. The number is written down
      // here rather than read off the constant it audits, which is
      // `gate_manifest_test.dart:44-50`'s rule and 11-01's.
      expect(SoakEventSchedule.eventStreamSalt, _declaredEventStreamSalt,
          reason: 'the event stream salt moved. Every event repro log ever '
              'printed describes a storm that no longer happens for its seed, '
              'and nothing else in this suite can see that — a same-seed '
              'comparison inside one build agrees with any salt at all');
    });

    test('seed 11 still generates the storm it generated when this line was '
        'written', () {
      // The golden, and it is deliberately the FIXED default seed
      // (11-CONTEXT ruling 4) at the FULL duration, because that is the storm
      // whose repro logs will actually be pasted into issues. It catches
      // every silent way reproduction can break at once: the salt, the
      // weights, the gap band, the order of the draws inside a case arm, an
      // extra draw inserted into the middle of the generator. None of those
      // is visible to a same-seed comparison.
      //
      // **This case is SUPPOSED to fail when the generator changes on
      // purpose.** The right response is to update the expectation in the
      // same commit and to say in that commit's message that every event
      // repro log printed before it is now void — not to loosen the case.
      final events = SoakEventSchedule.generate(
        seed: 11,
        duration: _fullSoak,
        panels: _panels,
        aliases: _aliases,
      );

      expect(events.length, _seed11EntryCount,
          reason: 'seed 11 at ${_fullSoak.inMinutes} min now generates '
              '${events.length} events rather than $_seed11EntryCount');
      expect(events.take(_seed11Head.length).map((e) => e.toString()).toList(),
          equals(_seed11Head),
          reason: 'the storm seed 11 describes has changed. Read the note '
              'above this case before touching the expectation');
      expect(events.last.toString(), _seed11Tail);
    });

    test('the default profile weights every drawable kind and nothing else',
        () {
      expect(SoakEventWeights.soak.byKind.keys,
          unorderedEquals(SoakEventKinds.drawable),
          reason: 'a drawable kind missing from the default profile is a '
              'lever no default storm can ever pull, which is the same silent '
              'gap the registry exists to prevent');
    });
  });

  group('the four exclusivity rules, over $_sweepSeeds seeds', () {
    late List<SoakEventGeneration> sweep;

    setUpAll(() {
      sweep = <SoakEventGeneration>[
        for (var seed = 0; seed < _sweepSeeds; seed++)
          SoakEventSchedule.generateReport(
            seed: seed,
            duration: _sweepDuration,
            panels: _panels,
            aliases: _aliases,
            minGap: _denseMinGap,
            maxGap: _denseMaxGap,
          ),
      ];
    });

    test('the sweep exercised every rule, and emitted every drawable kind',
        () {
      // Anti-vacuity, and it comes first for schedule_test.dart:134-143's
      // reason: each rule below resolves by SUPPRESSING a draw, so it leaves
      // nothing in the output to count. A sweep over a storm that never came
      // close to breaking a rule is green for a generator with no rule in it
      // at all.
      final totals = <String, int>{
        for (final rule in SoakExclusivityRules.all)
          rule: sweep.fold(0, (sum, g) => sum + (g.skipsByRule[rule] ?? 0)),
      };
      final emitted = <String>{
        for (final generation in sweep)
          for (final entry in generation.events) entry.event.kind,
      };

      // ignore: avoid_print
      print('exclusivity sweep over $_sweepSeeds seeds '
          '(${_sweepDuration.inMinutes} min, '
          '${_denseMinGap.inSeconds}-${_denseMaxGap.inSeconds}s band): '
          'suppressions $totals');

      for (final rule in <String>[
        SoakExclusivityRules.restartSeparation,
        SoakExclusivityRules.revocationPairing,
        SoakExclusivityRules.bumpOnDownAlias,
        SoakExclusivityRules.writeInFlight,
      ]) {
        expect(totals[rule], greaterThan(0),
            reason: 'rule "$rule" suppressed nothing across $_sweepSeeds '
                'seeds, so the arm asserting it holds was never asked '
                'anything. Either the band is too sparse to produce the '
                'conflict or the rule is not wired');
      }
      expect(emitted, containsAll(SoakEventKinds.all),
          reason: 'a kind the sweep never emitted is a kind whose rules the '
              'sweep never checked: $emitted');
    });

    test('rule 1: no gateway restart within 15 s of another', () {
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        Duration? previous;
        for (final entry in sweep[seed].events) {
          if (entry.event is! GatewayRestart) continue;
          if (previous != null) {
            expect(entry.offset - previous,
                greaterThanOrEqualTo(SoakEventSchedule.restartSeparation),
                reason: 'seed $seed restarts the gateway at $previous and '
                    'again at ${entry.offset}. A restart\'s own recovery has '
                    'not completed, so the run measures restart-during-restart '
                    '— which is F23\'s row and not this phase\'s');
          }
          previous = entry.offset;
        }
      }
    });

    test('rule 2: every revocation has its restore within 60 s, and no '
        'station ends the run revoked', () {
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        final revokedAt = <String, Duration>{};
        for (final entry in sweep[seed].events) {
          switch (entry.event) {
            case TokenRevocation(:final stationId):
              expect(revokedAt.containsKey(stationId), isFalse,
                  reason: 'seed $seed revokes $stationId twice with no '
                      'restore between, so the pairing is not one-to-one');
              revokedAt[stationId] = entry.offset;
            case TokenRestore(:final stationId):
              final since = revokedAt.remove(stationId);
              expect(since, isNotNull,
                  reason: 'seed $seed restores $stationId, which was never '
                      'revoked — a bare restore means the recovery is being '
                      'drawn rather than paired');
              expect(entry.offset - since!,
                  lessThanOrEqualTo(SoakEventSchedule.tokenRestoreWindow),
                  reason: 'seed $seed leaves $stationId revoked for '
                      '${entry.offset - since}');
            default:
              break;
          }
        }
        expect(revokedAt, isEmpty,
            reason: 'seed $seed ends its run with $revokedAt still revoked. A '
                'refused credential stops the redial loop by design (Phase 6), '
                'so those panels are gone for the rest of the run and every '
                'invariant they carried passes vacuously from that offset on');
      }
    });

    test('rule 3: no epoch bump on an alias that is currently down', () {
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        final down = <String>{};
        for (final entry in sweep[seed].events) {
          switch (entry.event) {
            case UpstreamLinkDown(:final alias):
              down.add(alias);
            case UpstreamLinkUp(:final alias):
              down.remove(alias);
            case UpstreamEpochBump(:final alias):
              expect(down, isNot(contains(alias)),
                  reason: 'seed $seed bumps $alias\'s epoch at '
                      '${entry.offset} while the link is down. 08-09 ordered '
                      'the degradation paths so they do not fight, and the '
                      'storm must not manufacture the state that phase '
                      'specifically avoided');
            default:
              break;
          }
        }
        expect(down, isEmpty,
            reason: 'seed $seed ends with $down still down: a link outage '
                'without its paired recovery is an alias dead for the rest of '
                'the run');
      }
    });

    test('rule 4: at most one write per panel in flight', () {
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        final lastWrite = <String, Duration>{};
        for (final entry in sweep[seed].events) {
          if (entry.event case PanelWrite(:final panel)) {
            final previous = lastWrite[panel];
            if (previous != null) {
              expect(entry.offset - previous,
                  greaterThanOrEqualTo(SoakEventSchedule.writeFlightWindow),
                  reason: 'seed $seed has $panel writing at $previous and '
                      'again at ${entry.offset}, inside the '
                      '${SoakEventSchedule.writeFlightWindow.inSeconds}s '
                      'write deadline. One cmd id is one operator action '
                      '(04-REVIEW CR-05); two in flight from one panel is a '
                      'different scenario and it is not this one');
            }
            lastWrite[panel] = entry.offset;
          }
        }
      }
    });

    test('the storm only ever names panels and aliases it was given', () {
      for (var seed = 0; seed < _sweepSeeds; seed++) {
        for (final entry in sweep[seed].events) {
          final named = switch (entry.event) {
            UpstreamLinkDown(:final alias) => alias,
            UpstreamLinkUp(:final alias) => alias,
            UpstreamEpochBump(:final alias) => alias,
            UpstreamMassDegrade(:final alias) => alias,
            UpstreamSlowResolve(:final alias) => alias,
            TokenRevocation(:final stationId) => stationId,
            TokenRestore(:final stationId) => stationId,
            PanelSubscribe(:final panel) => panel,
            PanelUnsubscribe(:final panel) => panel,
            PanelWrite(:final panel) => panel,
            PanelQuery(:final panel) => panel,
            GatewayRestart() || KeymappingReload() || PlantMutate() => null,
          };
          if (named == null) continue;
          expect(<String>[..._panels, ..._aliases], contains(named),
              reason: 'seed $seed targets "$named", which the caller did not '
                  'hand this generator. The never-faulted control panel is '
                  'excluded by NOT being passed in, so a generator that '
                  'invents a name would disconnect the one panel whose flat '
                  'reconnect count is every checker\'s strongest arm');
        }
      }
    });
  });

  group('mergeTotalOrder — the third sort key', () {
    test('two entries at one offset keep their order however many entries '
        'follow them, over $_mergeTrials merges', () {
      // **This is the case that would not exist if the merge sorted on offset
      // alone.** Dart's `List.sort` is a dual-pivot quicksort past a short
      // list, so it is not stable: two entries the comparator calls equal come
      // out in an order that depends on how the partitioning went, and the
      // partitioning depends on the LENGTH of the list. Comparing two
      // generations of one seed inside one build cannot see that — the input
      // is identical, so even an unstable sort is deterministic. What moves is
      // the day something else in the storm changes: one more link fault, a
      // fifteenth event kind, a longer duration. Then a pair of entries at one
      // offset somewhere else entirely can swap, and a repro log already
      // pasted into an issue stops describing the run it came from.
      //
      // So the perturbation here is the honest one: hold the colliding pair
      // fixed and add entries AFTER it, which cannot legitimately affect its
      // order, then check that it did not move.
      final linkBase = _fillerLink();
      final events = _fillerEvents();
      final reference = _orderAtCollision(mergeTotalOrder(linkBase, events));

      expect(reference, 'link,event',
          reason: 'the fixture must put exactly one link entry and one event '
              'at $_collisionOffset, or this case is measuring nothing: '
              '"$reference"');

      var agreed = 0;
      for (var extra = 1; extra <= _mergeTrials; extra++) {
        final link = <ScheduledFault>[
          ...linkBase,
          for (var i = 0; i < extra; i++)
            ScheduledFault(_collisionOffset + Duration(milliseconds: 1 + i),
                const BlackholeMutation()),
        ];
        if (_orderAtCollision(mergeTotalOrder(link, events)) == reference) {
          agreed++;
        }
      }

      expect(agreed, _mergeTrials,
          reason: '$agreed of $_mergeTrials merges kept the two entries at '
              '$_collisionOffset in the order $reference. Under a total order '
              'this cannot vary at all; anything less means the comparator is '
              'leaving ties for an unstable sort to break');
    });

    test('every entry carries a unique (stream, index) pair, so there are no '
        'ties for the sort to break', () {
      final merged = mergeTotalOrder(_fillerLink(), _fillerEvents(),
          quietClears: <ScheduledFault>[
            ScheduledFault(_collisionOffset, const FlapMutation.off()),
          ]);
      final keys = merged
          .map((e) => '${e.streamIndex}:${e.indexWithinStream}')
          .toSet();

      expect(keys, hasLength(merged.length),
          reason: 'two entries share a (stream, index) pair, so the "total" '
              'order is not total and the comparator can still return zero');
    });

    test('the merged list is in non-decreasing offset order', () {
      final merged = mergeTotalOrder(_fillerLink(), _fillerEvents());
      var previous = Duration.zero;
      for (final entry in merged) {
        expect(entry.offset, greaterThanOrEqualTo(previous));
        previous = entry.offset;
      }
    });
  });

  group('the generated quiet windows', () {
    test('are computed and printed at both arm durations', () {
      final short = computeStableWindows(_shortSoak);
      final full = computeStableWindows(_fullSoak);

      final buffer = StringBuffer('generated quiet windows:\n');
      for (final (label, duration, windows) in <(String, Duration, List<StableWindow>)>[
        ('90 s arm', _shortSoak, short),
        ('35 min arm', _fullSoak, full),
      ]) {
        final quiet = windows.fold(
            Duration.zero, (sum, w) => sum + w.length);
        buffer
          ..writeln('  $label (${duration.inSeconds} s): '
              '${windows.length} windows of '
              '${windows.isEmpty ? 0 : windows.first.length.inMilliseconds}ms, '
              'cadence ${windows.length < 2 ? "n/a" : (windows[1].start - windows[0].start).inMilliseconds}ms')
          ..writeln('    quiet ${quiet.inSeconds} s of ${duration.inSeconds} s '
              '(${(100 * quiet.inMicroseconds / duration.inMicroseconds).toStringAsFixed(1)} %), '
              'storm ${(duration - quiet).inSeconds} s')
          ..writeln('    $windows');
      }
      // ignore: avoid_print
      print(buffer);

      expect(full, hasLength(greaterThanOrEqualTo(8)),
          reason: 'invariant 3 needs windows to judge, and its floor is eight '
              'in a thirty-five-minute run (11-RESEARCH §B.3). Fewer means the '
              'checker fails its vacuity gate for a reason nobody chose');
      expect(short, hasLength(greaterThanOrEqualTo(2)),
          reason: 'the 90-second arm runs on every push and exists so the '
              'machinery cannot rot. An arm with no quiet window in it leaves '
              'invariant 3 unexercised on every push, which is the vacuity the '
              'whole apparatus refuses — arriving through the back door');

      for (final windows in <List<StableWindow>>[short, full]) {
        for (final window in windows) {
          expect(window.length, greaterThanOrEqualTo(minStableWindow),
              reason: 'a window shorter than the convergence floor reports '
                  'divergences that were simply not finished converging');
        }
      }
    });

    test('leave most of the run to the storm', () {
      // The other half of the previous case, and the reason the quiet fraction
      // is capped: eight windows in a ninety-second run would be eighty
      // seconds of silence, and the arm would be a soak in name only.
      for (final duration in <Duration>[
        _shortSoak,
        const Duration(minutes: 5),
        _fullSoak,
      ]) {
        final quiet = computeStableWindows(duration)
            .fold(Duration.zero, (sum, w) => sum + w.length);
        expect(quiet.inMicroseconds * quietFractionDenominator,
            lessThanOrEqualTo(duration.inMicroseconds),
            reason: 'a ${duration.inSeconds} s run would be quiet for '
                '${quiet.inSeconds} s, which is more than one '
                '$quietFractionDenominator of it. The fault-driven arms in '
                '11-04 and 11-05 need a storm to fire into');
      }
    });

    test('never overlap, and always end inside the run', () {
      for (var seconds = 20; seconds <= 3600; seconds += 37) {
        final duration = Duration(seconds: seconds);
        final windows = computeStableWindows(duration);
        Duration previousEnd = Duration.zero;
        for (final window in windows) {
          expect(window.start, greaterThanOrEqualTo(previousEnd),
              reason: 'windows overlap at ${duration.inSeconds} s: $windows');
          expect(window.end, lessThanOrEqualTo(duration),
              reason: 'a window runs past the end of a '
                  '${duration.inSeconds} s run: $windows');
          previousEnd = window.end;
        }
      }
    });

    test('a run too short to hold one gets none, rather than a sliver', () {
      expect(computeStableWindows(const Duration(seconds: 15)), isEmpty,
          reason: 'a fifteen-second run cannot hold a judgeable window inside '
              'the quiet cap. Returning a short one would let invariant 3 '
              'report residue that was only unconverged, which is worse than '
              'reporting no windows and failing the floor');
      expect(computeStableWindows(Duration.zero), isEmpty);
    });
  });

  group('buildTimeline — the whole storm', () {
    test('nothing is armed inside a quiet window', () {
      final timeline = _timeline(seed: 11, duration: _fullSoak);
      expect(timeline.stableWindows, isNotEmpty,
          reason: 'no windows, so this arm walks a list looking for entries '
              'inside intervals that do not exist and passes on any timeline '
              'at all');

      for (final window in timeline.stableWindows) {
        final inside = timeline.merged
            .where((e) => e.offset > window.start && e.offset < window.end)
            .toList();
        expect(inside, isEmpty,
            reason: 'the storm acts inside the quiet window $window, so '
                'invariant 3 would be asked to require convergence across a '
                'fault: $inside');
      }

      // And the clears did their job: walking the merged list up to each
      // window's start must leave nothing armed.
      for (final window in timeline.stableWindows) {
        final armed = <String>{};
        for (final entry in timeline.merged) {
          if (entry.offset > window.start) break;
          if (entry.payload case final FaultMutation mutation) {
            if (mutation.arms) {
              armed.add(mutation.mode);
            } else {
              armed.remove(mutation.mode);
            }
          }
        }
        expect(armed, isEmpty,
            reason: 'the window $window opens with $armed still armed. The '
                'injected clears are what make an interval with no entries in '
                'it actually quiet — an empty stretch after an arming draw is '
                'a fault held, not a fault absent');
      }
    });

    test('the clear map covers every mode the registry declares', () {
      // Pins the local copy of `ScenarioSchedule._clearFor` against the same
      // registry the original keys off, so a ninth mode fails here rather
      // than as a quiet window that is not quiet twenty minutes into a soak.
      for (final mode in faultModes) {
        if (mode == 'killOnce') {
          expect(() => clearForMode(mode), throwsStateError,
              reason: 'killOnce has no off lever, so a clear for it would be '
                  'a log line that lies');
          continue;
        }
        final clear = clearForMode(mode);
        expect(clear.mode, mode,
            reason: 'clearForMode("$mode") returns a ${clear.mode} mutation');
        expect(clear.arms, isFalse,
            reason: 'clearForMode("$mode") returns something that ARMS the '
                'mode, so every quiet window would open by turning the storm '
                'up');
      }
    });

    test('the repro log names everything needed to regenerate the run', () {
      final timeline = _timeline(seed: 11, duration: _fullSoak);
      final log = timeline.reproLog;
      final header = log.split('\n').take(6).join('\n');
      // ignore: avoid_print
      print('repro log header (seed 11, 35 min):\n$header\n'
          '  ... ${timeline.merged.length} merged entries follow');

      for (final needle in <String>[
        'seed=11',
        '0x50AC',
        '${SoakEventSchedule.eventSeedFor(11)}',
        'band=1-10s',
        'band=10-40s',
        'panels ${_panels.length}',
        'aliases ${_aliases.length}',
        'quiet ',
      ]) {
        expect(header, contains(needle),
            reason: 'the repro log header does not name "$needle", so a log '
                'pasted into an issue is no longer self-contained — a reader '
                'has to know which cadence, which weights or which population '
                'the failing soak used. That property is '
                'scenario_schedule.dart:560-563\'s and it has to survive the '
                'merge:\n$header');
      }
      expect(log.split('\n'), hasLength(greaterThan(timeline.merged.length)),
          reason: 'the log is a header and then every merged entry');
    });

    test('ROADMAP criterion 3, on the merged timeline: one seed, two '
        'generations, one storm', () {
      // The hard half of this was delivered in Phase 2 and is not rebuilt
      // here: `schedule_test.dart:42` and `:233` prove same-seed-identical
      // timeline for the link half, across generation and playback. This case
      // proves the merge did not break it.
      final first = _timeline(seed: 2026, duration: _fullSoak);
      final second = _timeline(seed: 2026, duration: _fullSoak);

      // ignore: avoid_print
      print('criterion 3: compared ${first.merged.length} merged entries '
          '(${first.link.length} link generated, ${first.events.length} '
          'events, ${first.quietClears.length} injected clears, '
          '${first.linkEntriesWithheld} link entries withheld)');

      expect(second.merged, equals(first.merged),
          reason: 'two generations of seed 2026 produced different merged '
              'timelines, so a soak failure cannot be reproduced from its '
              'seed. Element-wise rather than by length: a generator that '
              'drifted in its payloads while keeping its cadence would '
              'produce two lists of one length describing two different runs');
      expect(first.merged, isNotEmpty,
          reason: 'two empty lists are equal');
    });

    test('the link half is bit-identical to ScenarioSchedule.generate alone',
        () {
      // **This is the half that proves the salt did its job.** If the two
      // streams shared a generator, adding or removing an event kind would
      // shift the link timeline for this seed — and every link repro log
      // already pasted into an issue would describe a storm that no longer
      // happens. The salt is what makes the two independent, and this case is
      // what makes the independence checkable.
      const seed = 2026;
      final alone = ScenarioSchedule.generate(seed: seed, duration: _fullSoak);
      final timeline = _timeline(seed: seed, duration: _fullSoak);

      // ignore: avoid_print
      print('link-half identity: compared ${alone.length} entries against '
          '${timeline.link.length}');

      expect(timeline.link, equals(alone),
          reason: 'buildTimeline\'s link half is not what '
              'ScenarioSchedule.generate produces for seed $seed on its own. '
              'Either the link half is being regenerated with different '
              'arguments or the two streams share an RNG');
      expect(
          ScenarioSchedule.reproLog(seed: seed, timeline: timeline.link),
          equals(ScenarioSchedule.reproLog(seed: seed, timeline: alone)),
          reason: 'and byte-identical once serialised, because the serialised '
              'form is what a human pastes back');
    });

    test('the two repro logs for one seed are string-identical', () {
      final first = _timeline(seed: 2026, duration: _fullSoak).reproLog;
      final second = _timeline(seed: 2026, duration: _fullSoak).reproLog;

      expect(second, equals(first),
          reason: 'the repro log is the artifact; two generations of one seed '
              'whose logs differ mean the artifact is not reproducible even '
              'where the timeline is');
      expect(first.split('\n'), hasLength(greaterThan(100)),
          reason: 'two short strings are equal too');
    });

    test('the merged half-counts add up', () {
      final timeline = _timeline(seed: 11, duration: _fullSoak);
      expect(
          timeline.merged.length,
          timeline.events.length +
              timeline.quietClears.length +
              timeline.link.length -
              timeline.linkEntriesWithheld,
          reason: 'the merged list is the two halves plus the injected clears, '
              'minus the link entries the windows withheld. If it is not, '
              'something is being dropped or counted twice');
      expect(timeline.linkEntriesWithheld, greaterThan(0),
          reason: 'no link entry fell inside any of '
              '${timeline.stableWindows.length} windows over '
              '${_fullSoak.inMinutes} minutes at a 1-10 s cadence, which is '
              'not credible — the withholding is not happening and the '
              'windows are quiet only because nothing was scheduled there');
    });
  });
}
